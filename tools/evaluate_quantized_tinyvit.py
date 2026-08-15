#!/usr/bin/env python3
"""Bit-oriented host reference for the bare-metal TinyViT schedule."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

from train_tinyvit import (TinyViT, make_tensors, choose_fraction, quantize,
                           linear_parameters, download_dataset)


EXP_FRACTION = np.asarray([
    32767, 32065, 31378, 30705, 30047, 29404, 28774, 28157,
    27554, 26963, 26385, 25820, 25267, 24725, 24196, 23677,
    23170, 22673, 22187, 21712, 21247, 20791, 20346, 19910,
    19483, 19066, 18657, 18258, 17866, 17483, 17109, 16742,
], dtype=np.int64)


def requant(value: np.ndarray, shift: int, relu: bool = False) -> np.ndarray:
    value = value.astype(np.int64)
    if shift:
        magnitude = np.abs(value)
        rounded = (magnitude + (1 << (shift - 1))) >> shift
        value = np.where(value < 0, -rounded, rounded)
    if relu:
        value = np.maximum(value, 0)
    return np.clip(value, -128, 127).astype(np.int8)


def rmsnorm(value: np.ndarray, gain: np.ndarray, output_fraction: int = 5,
            gain_fraction: int = 6) -> np.ndarray:
    wide = value.astype(np.int64)
    mean_square = np.sum(wide * wide, axis=-1) // value.shape[-1]
    rms = np.maximum(np.floor(np.sqrt(mean_square)).astype(np.int64), 1)
    numerator = wide * gain.astype(np.int64) * (1 << output_fraction)
    denominator = rms[..., None] * (1 << gain_fraction)
    magnitude = (np.abs(numerator) + denominator // 2) // denominator
    result = np.where(numerator < 0, -magnitude, magnitude)
    return np.clip(result, -128, 127).astype(np.int8)


def softmax_hw(score: np.ndarray, score_shift: int) -> np.ndarray:
    maximum = score.max(axis=-1, keepdims=True).astype(np.int64)
    delta = np.clip((maximum - score.astype(np.int64)) >> score_shift, 0, 255)
    exponent = EXP_FRACTION[delta & 31] >> (delta >> 5)
    total = exponent.sum(axis=-1)
    msb = np.floor(np.log2(total)).astype(np.int64)
    mantissa = np.where(msb >= 7, total >> (msb - 7), total << (7 - msb))
    reciprocal = np.rint((127 * 65536) / mantissa).astype(np.int64)
    product = exponent * reciprocal[..., None]
    norm_shift = msb + 9
    rounded = (product + (1 << (norm_shift[..., None] - 1))) >> norm_shift[..., None]
    return np.clip(rounded, 0, 127).astype(np.int8)


def build_parameters(model: TinyViT):
    frac_input, frac_token, frac_qkv = 7, 5, 5
    frac_context, frac_hidden, frac_final = 5, 4, 5
    patch_w = model.patch.weight.detach().numpy()[:, 0].reshape(32, 16).T
    patch_b = model.patch.bias.detach().numpy()
    patch_wf = choose_fraction(patch_w)
    result = {
        "patch_w": quantize(patch_w, patch_wf),
        "patch_b": quantize(patch_b, frac_input + patch_wf, np.int32),
        "patch_shift": frac_input + patch_wf - frac_token,
        "position": quantize(model.position.detach().numpy()[0], frac_token),
        "norm1": quantize(model.norm1.weight.detach().numpy(), 6),
        "norm2": quantize(model.norm2.weight.detach().numpy(), 6),
        "norm3": quantize(model.norm3.weight.detach().numpy(), 6),
    }
    for name, layer, fi, fo, padded in [
        ("q", model.q, frac_token, frac_qkv, None),
        ("k", model.k, frac_token, frac_qkv, None),
        ("v", model.v, frac_token, frac_qkv, None),
        ("projection", model.projection, frac_context, frac_token, None),
        ("mlp1", model.mlp1, frac_token, frac_hidden, None),
        ("mlp2", model.mlp2, frac_hidden, frac_token, None),
        ("classifier", model.classifier, frac_final, 0, 12),
    ]:
        weight, bias, weight_fraction, shift = linear_parameters(
            layer, fi, fo, padded_outputs=padded)
        result[name + "_w"] = weight
        result[name + "_b"] = bias
        result[name + "_shift"] = shift
        result[name + "_wf"] = weight_fraction
    return result


def infer(images: np.ndarray, parameter: dict) -> tuple[np.ndarray, np.ndarray]:
    batch = images.shape[0]
    pixel = np.rint(images[:, 0] * 127.0).astype(np.int8)
    patch = pixel.reshape(batch, 1, 8, 4, 8, 4).transpose(0, 2, 4, 3, 5, 1)
    patch = patch.reshape(batch, 64, 16)
    token = requant(patch.astype(np.int32) @ parameter["patch_w"].astype(np.int32)
                    + parameter["patch_b"], parameter["patch_shift"])
    token = np.clip(token.astype(np.int16) + parameter["position"], -128, 127).astype(np.int8)
    normal = rmsnorm(token, parameter["norm1"])

    projected = {}
    for name in ("q", "k", "v"):
        projected[name] = requant(
            normal.astype(np.int32) @ parameter[name + "_w"].astype(np.int32)
            + parameter[name + "_b"], parameter[name + "_shift"])
        projected[name] = projected[name].reshape(batch, 64, 4, 8).transpose(0, 2, 1, 3)

    score = projected["q"].astype(np.int32) @ projected["k"].astype(np.int32).transpose(0, 1, 3, 2)
    probability = softmax_hw(score, 6)
    context = requant(probability.astype(np.int32) @ projected["v"].astype(np.int32), 7)
    context = context.transpose(0, 2, 1, 3).reshape(batch, 64, 32)
    projection = requant(
        context.astype(np.int32) @ parameter["projection_w"].astype(np.int32)
        + parameter["projection_b"], parameter["projection_shift"])
    token = np.clip(token.astype(np.int16) + projection.astype(np.int16), -128, 127).astype(np.int8)

    normal = rmsnorm(token, parameter["norm2"])
    hidden = requant(normal.astype(np.int32) @ parameter["mlp1_w"].astype(np.int32)
                     + parameter["mlp1_b"], parameter["mlp1_shift"], relu=True)
    mlp = requant(hidden.astype(np.int32) @ parameter["mlp2_w"].astype(np.int32)
                  + parameter["mlp2_b"], parameter["mlp2_shift"])
    token = np.clip(token.astype(np.int16) + mlp.astype(np.int16), -128, 127).astype(np.int8)
    final = rmsnorm(token, parameter["norm3"])
    pooled = np.rint(final.astype(np.int32).mean(axis=1)).astype(np.int8)
    logits = pooled.astype(np.int32) @ parameter["classifier_w"].astype(np.int32)
    logits += parameter["classifier_b"]
    return logits[:, :10], probability


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path("tools/.cache/fashion-mnist"))
    parser.add_argument("--checkpoint", type=Path,
                        default=Path("tools/tinyvit_fashion.pt"))
    parser.add_argument("--samples", type=int, default=2000)
    parser.add_argument("--batch-size", type=int, default=100)
    args = parser.parse_args()
    download_dataset(args.data_dir)
    _, _, test_x, test_y, _, _ = make_tensors(args.data_dir, 1)
    model = TinyViT()
    model.load_state_dict(torch.load(args.checkpoint, map_location="cpu"))
    model.eval()
    parameter = build_parameters(model)
    correct = 0
    float_correct = 0
    count = min(args.samples, len(test_x))
    for start in range(0, count, args.batch_size):
        image = test_x[start:start + args.batch_size].numpy()
        label = test_y[start:start + args.batch_size].numpy()
        logits, _ = infer(image, parameter)
        correct += int((logits.argmax(1) == label).sum())
        with torch.no_grad():
            float_correct += int((model(test_x[start:start + args.batch_size]).argmax(1)
                                  == test_y[start:start + args.batch_size]).sum())
    print(f"integer accuracy: {correct}/{count} = {correct / count:.2%}")
    print(f"float subset:     {float_correct}/{count} = {float_correct / count:.2%}")


if __name__ == "__main__":
    main()
