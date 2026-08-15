#!/usr/bin/env python3
"""Train and export the 32-d TinyViT used by the FPGA demonstration.

The script deliberately avoids torchvision: it downloads the four canonical
IDX gzip files, parses them directly, trains a single-block transformer, and
emits a self-contained int8 C header.  The runtime maps every Linear operation
to an LSME descriptor while the CPU performs RMSNorm, residuals and reshaping.
"""

from __future__ import annotations

import argparse
import gzip
import math
import os
import random
import struct
import urllib.request
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset


DATA_URL = "https://storage.googleapis.com/tensorflow/tf-keras-datasets/"
FILES = {
    "train-images-idx3-ubyte.gz": (2051, 60_000),
    "train-labels-idx1-ubyte.gz": (2049, 60_000),
    "t10k-images-idx3-ubyte.gz": (2051, 10_000),
    "t10k-labels-idx1-ubyte.gz": (2049, 10_000),
}
CLASS_NAMES = [
    "T-shirt/top", "Trouser", "Pullover", "Dress", "Coat",
    "Sandal", "Shirt", "Sneaker", "Bag", "Ankle boot",
]


def download_dataset(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        target = root / name
        if target.exists() and target.stat().st_size > 1000:
            continue
        print(f"download {name}")
        temp = target.with_suffix(target.suffix + ".part")
        urllib.request.urlretrieve(DATA_URL + name, temp)
        temp.replace(target)


def read_idx(path: Path, expected_magic: int) -> np.ndarray:
    with gzip.open(path, "rb") as stream:
        magic, count = struct.unpack(">II", stream.read(8))
        if magic != expected_magic:
            raise ValueError(f"{path}: magic {magic}, expected {expected_magic}")
        if magic == 2051:
            rows, cols = struct.unpack(">II", stream.read(8))
            data = np.frombuffer(stream.read(), dtype=np.uint8)
            return data.reshape(count, rows, cols).copy()
        return np.frombuffer(stream.read(), dtype=np.uint8, count=count).copy()


class RMSNorm(nn.Module):
    def __init__(self, dimension: int, epsilon: float = 1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(dimension))
        self.epsilon = epsilon

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        scale = torch.rsqrt(value.square().mean(dim=-1, keepdim=True) + self.epsilon)
        return value * scale * self.weight


class TinyViT(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.patch = nn.Conv2d(1, 32, kernel_size=4, stride=4, bias=True)
        self.position = nn.Parameter(torch.zeros(1, 64, 32))
        self.norm1 = RMSNorm(32)
        self.q = nn.Linear(32, 32)
        self.k = nn.Linear(32, 32)
        self.v = nn.Linear(32, 32)
        self.projection = nn.Linear(32, 32)
        self.norm2 = RMSNorm(32)
        self.mlp1 = nn.Linear(32, 64)
        self.mlp2 = nn.Linear(64, 32)
        self.norm3 = RMSNorm(32)
        self.classifier = nn.Linear(32, 10)
        nn.init.trunc_normal_(self.position, std=0.02)

    def forward(self, image: torch.Tensor, return_attention: bool = False):
        token = self.patch(image).flatten(2).transpose(1, 2)
        token = token + self.position
        normal = self.norm1(token)
        batch = image.shape[0]
        q = self.q(normal).view(batch, 64, 4, 8).transpose(1, 2)
        k = self.k(normal).view(batch, 64, 4, 8).transpose(1, 2)
        v = self.v(normal).view(batch, 64, 4, 8).transpose(1, 2)
        attention = torch.softmax((q @ k.transpose(-1, -2)) / math.sqrt(8.0), dim=-1)
        context = (attention @ v).transpose(1, 2).reshape(batch, 64, 32)
        token = token + self.projection(context)
        normal = self.norm2(token)
        token = token + self.mlp2(torch.relu(self.mlp1(normal)))
        pooled = self.norm3(token).mean(dim=1)
        logits = self.classifier(pooled)
        if return_attention:
            return logits, attention
        return logits


def make_tensors(data_dir: Path, limit_train: int):
    train_image = read_idx(data_dir / "train-images-idx3-ubyte.gz", 2051)
    train_label = read_idx(data_dir / "train-labels-idx1-ubyte.gz", 2049)
    test_image = read_idx(data_dir / "t10k-images-idx3-ubyte.gz", 2051)
    test_label = read_idx(data_dir / "t10k-labels-idx1-ubyte.gz", 2049)
    if limit_train:
        train_image = train_image[:limit_train]
        train_label = train_label[:limit_train]

    def convert(images: np.ndarray) -> torch.Tensor:
        padded = np.pad(images, ((0, 0), (2, 2), (2, 2)), mode="constant")
        return torch.from_numpy(padded).unsqueeze(1).float().div_(255.0)

    return convert(train_image), torch.from_numpy(train_label.astype(np.int64)), \
        convert(test_image), torch.from_numpy(test_label.astype(np.int64)), \
        test_image, test_label


@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device) -> float:
    model.eval()
    correct = 0
    count = 0
    for image, label in loader:
        image = image.to(device)
        label = label.to(device)
        prediction = model(image).argmax(dim=1)
        correct += int((prediction == label).sum())
        count += label.numel()
    return correct / count


def choose_fraction(value: np.ndarray, maximum: int = 12) -> int:
    peak = float(np.max(np.abs(value)))
    if peak == 0:
        return maximum
    return max(0, min(maximum, int(math.floor(math.log2(127.0 / peak)))))


def quantize(value: np.ndarray, fraction: int, dtype=np.int8) -> np.ndarray:
    scaled = np.rint(value * (1 << fraction))
    if dtype == np.int8:
        scaled = np.clip(scaled, -128, 127)
    elif dtype == np.int32:
        scaled = np.clip(scaled, -(1 << 31), (1 << 31) - 1)
    return scaled.astype(dtype)


def linear_parameters(layer: nn.Linear, input_fraction: int, output_fraction: int,
                      padded_outputs: int | None = None):
    weight = layer.weight.detach().cpu().numpy().T
    bias = layer.bias.detach().cpu().numpy()
    if padded_outputs is not None:
        pad = padded_outputs - weight.shape[1]
        weight = np.pad(weight, ((0, 0), (0, pad)))
        bias = np.pad(bias, (0, pad))
    weight_fraction = choose_fraction(weight)
    weight_q = quantize(weight, weight_fraction)
    bias_q = quantize(bias, input_fraction + weight_fraction, np.int32)
    shift = input_fraction + weight_fraction - output_fraction
    if shift < 0 or shift > 31:
        raise ValueError(f"unsupported shift {shift}")
    return weight_q, bias_q, weight_fraction, shift


EXP_FRACTION = np.asarray([
    32767, 32065, 31378, 30705, 30047, 29404, 28774, 28157,
    27554, 26963, 26385, 25820, 25267, 24725, 24196, 23677,
    23170, 22673, 22187, 21712, 21247, 20791, 20346, 19910,
    19483, 19066, 18657, 18258, 17866, 17483, 17109, 16742,
], dtype=np.int64)


def requant_reference(value: np.ndarray, shift: int,
                      relu: bool = False) -> np.ndarray:
    """Match the sign/magnitude rounding used by LSME STZA."""
    value = value.astype(np.int64)
    if shift:
        magnitude = np.abs(value)
        rounded = (magnitude + (1 << (shift - 1))) >> shift
        value = np.where(value < 0, -rounded, rounded)
    if relu:
        value = np.maximum(value, 0)
    return np.clip(value, -128, 127).astype(np.int8)


def rmsnorm_reference(value: np.ndarray, gain: np.ndarray,
                      output_fraction: int = 5,
                      gain_fraction: int = 6) -> np.ndarray:
    wide = value.astype(np.int64)
    mean_square = np.sum(wide * wide, axis=-1) // value.shape[-1]
    rms = np.maximum(np.floor(np.sqrt(mean_square)).astype(np.int64), 1)
    numerator = wide * gain.astype(np.int64) * (1 << output_fraction)
    denominator = rms[..., None] * (1 << gain_fraction)
    magnitude = (np.abs(numerator) + denominator // 2) // denominator
    result = np.where(numerator < 0, -magnitude, magnitude)
    return np.clip(result, -128, 127).astype(np.int8)


def softmax_reference(score: np.ndarray, score_shift: int) -> np.ndarray:
    maximum = score.max(axis=-1, keepdims=True).astype(np.int64)
    delta = np.clip((maximum - score.astype(np.int64)) >> score_shift, 0, 255)
    exponent = EXP_FRACTION[delta & 31] >> (delta >> 5)
    total = exponent.sum(axis=-1)
    msb = np.floor(np.log2(total)).astype(np.int64)
    mantissa = np.where(msb >= 7, total >> (msb - 7), total << (7 - msb))
    reciprocal = np.rint((127 * 65536) / mantissa).astype(np.int64)
    product = exponent * reciprocal[..., None]
    norm_shift = msb + 9
    rounded = (product + (1 << (norm_shift[..., None] - 1))) \
        >> norm_shift[..., None]
    return np.clip(rounded, 0, 127).astype(np.int8)


def integer_reference(raw_images: np.ndarray, parameter: dict) -> np.ndarray:
    """Bit-oriented model used to select robust on-board demo examples."""
    padded = np.pad(raw_images, ((0, 0), (2, 2), (2, 2)), mode="constant")
    pixel = np.rint(padded.astype(np.float64) * (127.0 / 255.0)).astype(np.int8)
    batch = pixel.shape[0]
    patch = pixel.reshape(batch, 1, 8, 4, 8, 4) \
        .transpose(0, 2, 4, 3, 5, 1).reshape(batch, 64, 16)
    token = requant_reference(
        patch.astype(np.int32) @ parameter["patch_w"].astype(np.int32)
        + parameter["patch_b"], parameter["patch_shift"])
    token = np.clip(token.astype(np.int16) + parameter["position"],
                    -128, 127).astype(np.int8)
    normal = rmsnorm_reference(token, parameter["norm1"])

    projected = {}
    for name in ("q", "k", "v"):
        projected[name] = requant_reference(
            normal.astype(np.int32) @ parameter[name + "_w"].astype(np.int32)
            + parameter[name + "_b"], parameter[name + "_shift"])
        projected[name] = projected[name].reshape(batch, 64, 4, 8) \
            .transpose(0, 2, 1, 3)

    score = projected["q"].astype(np.int32) \
        @ projected["k"].astype(np.int32).transpose(0, 1, 3, 2)
    probability = softmax_reference(score, 6)
    context = requant_reference(
        probability.astype(np.int32) @ projected["v"].astype(np.int32), 7)
    context = context.transpose(0, 2, 1, 3).reshape(batch, 64, 32)
    projection = requant_reference(
        context.astype(np.int32) @ parameter["projection_w"].astype(np.int32)
        + parameter["projection_b"], parameter["projection_shift"])
    token = np.clip(token.astype(np.int16) + projection.astype(np.int16),
                    -128, 127).astype(np.int8)

    normal = rmsnorm_reference(token, parameter["norm2"])
    hidden = requant_reference(
        normal.astype(np.int32) @ parameter["mlp1_w"].astype(np.int32)
        + parameter["mlp1_b"], parameter["mlp1_shift"], relu=True)
    mlp = requant_reference(
        hidden.astype(np.int32) @ parameter["mlp2_w"].astype(np.int32)
        + parameter["mlp2_b"], parameter["mlp2_shift"])
    token = np.clip(token.astype(np.int16) + mlp.astype(np.int16),
                    -128, 127).astype(np.int8)
    final = rmsnorm_reference(token, parameter["norm3"])
    pooled = np.rint(final.astype(np.int32).mean(axis=1)).astype(np.int8)
    logits = pooled.astype(np.int32) @ parameter["classifier_w"].astype(np.int32)
    return logits[:, :10] + parameter["classifier_b"][:10]


def format_c_array(name: str, value: np.ndarray, c_type: str, columns: int = 16) -> str:
    flat = value.reshape(-1)
    lines = [f"static const {c_type} {name}[{flat.size}] __attribute__((aligned(64))) = {{"]
    for start in range(0, flat.size, columns):
        chunk = ", ".join(str(int(item)) for item in flat[start:start + columns])
        lines.append("    " + chunk + ",")
    lines.append("};")
    return "\n".join(lines)


def export_header(model: TinyViT, raw_test: np.ndarray, test_labels: np.ndarray,
                  output: Path, accuracy: float) -> None:
    # Power-of-two activation formats used by the bare-metal integer runtime.
    frac_input = 7
    frac_token = 5
    frac_qkv = 5
    frac_context = 5
    frac_hidden = 4
    frac_final = 5

    patch_weight = model.patch.weight.detach().cpu().numpy()[:, 0].reshape(32, 16).T
    patch_bias = model.patch.bias.detach().cpu().numpy()
    patch_w_frac = choose_fraction(patch_weight)
    patch_w_q = quantize(patch_weight, patch_w_frac)
    patch_b_q = quantize(patch_bias, frac_input + patch_w_frac, np.int32)
    patch_shift = frac_input + patch_w_frac - frac_token

    q_w, q_b, q_wf, q_shift = linear_parameters(model.q, frac_token, frac_qkv)
    k_w, k_b, k_wf, k_shift = linear_parameters(model.k, frac_token, frac_qkv)
    v_w, v_b, v_wf, v_shift = linear_parameters(model.v, frac_token, frac_qkv)
    proj_w, proj_b, proj_wf, proj_shift = linear_parameters(
        model.projection, frac_context, frac_token)
    mlp1_w, mlp1_b, mlp1_wf, mlp1_shift = linear_parameters(
        model.mlp1, frac_token, frac_hidden)
    mlp2_w, mlp2_b, mlp2_wf, mlp2_shift = linear_parameters(
        model.mlp2, frac_hidden, frac_token)
    cls_w, cls_b, cls_wf, _ = linear_parameters(
        model.classifier, frac_final, 0, padded_outputs=12)

    position_q = quantize(model.position.detach().cpu().numpy()[0], frac_token)
    norm_gain_fraction = 6
    norm1_q = quantize(model.norm1.weight.detach().cpu().numpy(), norm_gain_fraction)
    norm2_q = quantize(model.norm2.weight.detach().cpu().numpy(), norm_gain_fraction)
    norm3_q = quantize(model.norm3.weight.detach().cpu().numpy(), norm_gain_fraction)

    # Choose one deterministic, high-margin integer-correct example per class.
    # This keeps the live FPGA demo stable while still using untouched test data.
    integer_parameter = {
        "patch_w": patch_w_q,
        "patch_b": patch_b_q,
        "patch_shift": patch_shift,
        "position": position_q,
        "norm1": norm1_q,
        "q_w": q_w,
        "q_b": q_b,
        "q_shift": q_shift,
        "k_w": k_w,
        "k_b": k_b,
        "k_shift": k_shift,
        "v_w": v_w,
        "v_b": v_b,
        "v_shift": v_shift,
        "projection_w": proj_w,
        "projection_b": proj_b,
        "projection_shift": proj_shift,
        "norm2": norm2_q,
        "mlp1_w": mlp1_w,
        "mlp1_b": mlp1_b,
        "mlp1_shift": mlp1_shift,
        "mlp2_w": mlp2_w,
        "mlp2_b": mlp2_b,
        "mlp2_shift": mlp2_shift,
        "norm3": norm3_q,
        "classifier_w": cls_w,
        "classifier_b": cls_b,
    }
    examples = []
    labels = []
    indices = []
    for class_id in range(10):
        candidates = np.flatnonzero(test_labels == class_id)[:256]
        logits = integer_reference(raw_test[candidates], integer_parameter)
        predictions = logits.argmax(axis=1)
        good_mask = predictions == class_id
        if good_mask.any():
            good_logits = logits[good_mask]
            top_two = np.partition(good_logits, -2, axis=1)[:, -2:]
            margin = top_two.max(axis=1) - top_two.min(axis=1)
            good_candidates = candidates[good_mask]
            index = int(good_candidates[int(margin.argmax())])
        else:
            index = int(candidates[0])
        examples.append(raw_test[index])
        labels.append(class_id)
        indices.append(index)
    examples_np = np.stack(examples)
    demo_logits = integer_reference(examples_np, integer_parameter)
    integer_correct = 0
    for start in range(0, len(raw_test), 100):
        logits = integer_reference(raw_test[start:start + 100], integer_parameter)
        integer_correct += int((logits.argmax(axis=1)
                                == test_labels[start:start + 100]).sum())
    integer_accuracy = integer_correct / len(raw_test)

    arrays = [
        format_c_array("tinyvit_patch_weight", patch_w_q, "int8_t"),
        format_c_array("tinyvit_patch_bias", patch_b_q, "int32_t", 8),
        format_c_array("tinyvit_position", position_q, "int8_t"),
        format_c_array("tinyvit_norm1_gain", norm1_q, "int8_t"),
        format_c_array("tinyvit_q_weight", q_w, "int8_t"),
        format_c_array("tinyvit_q_bias", q_b, "int32_t", 8),
        format_c_array("tinyvit_k_weight", k_w, "int8_t"),
        format_c_array("tinyvit_k_bias", k_b, "int32_t", 8),
        format_c_array("tinyvit_v_weight", v_w, "int8_t"),
        format_c_array("tinyvit_v_bias", v_b, "int32_t", 8),
        format_c_array("tinyvit_projection_weight", proj_w, "int8_t"),
        format_c_array("tinyvit_projection_bias", proj_b, "int32_t", 8),
        format_c_array("tinyvit_norm2_gain", norm2_q, "int8_t"),
        format_c_array("tinyvit_mlp1_weight", mlp1_w, "int8_t"),
        format_c_array("tinyvit_mlp1_bias", mlp1_b, "int32_t", 8),
        format_c_array("tinyvit_mlp2_weight", mlp2_w, "int8_t"),
        format_c_array("tinyvit_mlp2_bias", mlp2_b, "int32_t", 8),
        format_c_array("tinyvit_norm3_gain", norm3_q, "int8_t"),
        format_c_array("tinyvit_classifier_weight", cls_w, "int8_t"),
        format_c_array("tinyvit_classifier_bias", cls_b, "int32_t", 8),
        format_c_array("tinyvit_demo_images", examples_np, "uint8_t", 28),
        format_c_array("tinyvit_demo_labels", np.asarray(labels, dtype=np.uint8), "uint8_t", 10),
        format_c_array("tinyvit_demo_indices", np.asarray(indices, dtype=np.uint16),
                       "uint16_t", 10),
        format_c_array("tinyvit_demo_expected_logits", demo_logits,
                       "int32_t", 10),
    ]

    constants = {
        "TINYVIT_FLOAT_TEST_ACCURACY_X10000": round(accuracy * 10000),
        "TINYVIT_INTEGER_TEST_ACCURACY_X10000": round(integer_accuracy * 10000),
        "TINYVIT_FRAC_INPUT": frac_input,
        "TINYVIT_FRAC_TOKEN": frac_token,
        "TINYVIT_FRAC_QKV": frac_qkv,
        "TINYVIT_FRAC_CONTEXT": frac_context,
        "TINYVIT_FRAC_HIDDEN": frac_hidden,
        "TINYVIT_FRAC_FINAL": frac_final,
        "TINYVIT_NORM_GAIN_FRAC": norm_gain_fraction,
        "TINYVIT_PATCH_SHIFT": patch_shift,
        "TINYVIT_Q_SHIFT": q_shift,
        "TINYVIT_K_SHIFT": k_shift,
        "TINYVIT_V_SHIFT": v_shift,
        "TINYVIT_PROJECTION_SHIFT": proj_shift,
        "TINYVIT_MLP1_SHIFT": mlp1_shift,
        "TINYVIT_MLP2_SHIFT": mlp2_shift,
        "TINYVIT_CLASSIFIER_ACC_FRAC": frac_final + cls_wf,
        "TINYVIT_ATTENTION_SCORE_SHIFT": 6,
        "TINYVIT_CONTEXT_SHIFT": 7,
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as stream:
        stream.write("#ifndef TINYVIT_MODEL_H\n#define TINYVIT_MODEL_H\n\n")
        stream.write("#include <stdint.h>\n\n")
        for name, value in constants.items():
            stream.write(f"#define {name} {value}\n")
        stream.write("\n")
        for array in arrays:
            stream.write(array + "\n\n")
        names = ", ".join('"' + item + '"' for item in CLASS_NAMES)
        stream.write(f"static const char *const tinyvit_class_names[10] = {{{names}}};\n\n")
        stream.write("#endif\n")
    print(f"wrote {output} ({output.stat().st_size / 1024:.1f} KiB)")
    print("weight fractions:", patch_w_frac, q_wf, k_wf, v_wf,
          proj_wf, mlp1_wf, mlp2_wf, cls_wf)
    print(f"integer reference accuracy: {integer_accuracy:.4%}")
    print("demo test indices:", indices)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path("tools/.cache/fashion-mnist"))
    parser.add_argument("--output", type=Path,
                        default=Path("sdk/software/examples/tinyvit_demo/tinyvit_model.h"))
    parser.add_argument("--checkpoint", type=Path,
                        default=Path("tools/tinyvit_fashion.pt"))
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--limit-train", type=int, default=0)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--learning-rate", type=float, default=2e-3)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--load-checkpoint", action="store_true")
    args = parser.parse_args()

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.set_num_threads(max(1, min(12, os.cpu_count() or 1)))
    download_dataset(args.data_dir)
    train_x, train_y, test_x, test_y, raw_test, raw_label = make_tensors(
        args.data_dir, args.limit_train)
    train_loader = DataLoader(TensorDataset(train_x, train_y),
                              batch_size=args.batch_size, shuffle=True)
    test_loader = DataLoader(TensorDataset(test_x, test_y),
                             batch_size=args.batch_size * 2)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"device={device}, train={len(train_x)}, test={len(test_x)}")
    model = TinyViT().to(device)

    if args.load_checkpoint and args.checkpoint.exists():
        model.load_state_dict(torch.load(args.checkpoint, map_location=device))
    else:
        optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate,
                                      weight_decay=1e-3)
        scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer, T_max=max(1, args.epochs))
        best = 0.0
        for epoch in range(1, args.epochs + 1):
            model.train()
            total_loss = 0.0
            total = 0
            for image, label in train_loader:
                image = image.to(device)
                label = label.to(device)
                optimizer.zero_grad(set_to_none=True)
                loss = nn.functional.cross_entropy(model(image), label)
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                total_loss += float(loss.detach()) * label.numel()
                total += label.numel()
            scheduler.step()
            accuracy = evaluate(model, test_loader, device)
            print(f"epoch={epoch} loss={total_loss / total:.4f} test={accuracy:.4%}")
            if accuracy >= best:
                best = accuracy
                args.checkpoint.parent.mkdir(parents=True, exist_ok=True)
                torch.save(model.state_dict(), args.checkpoint)
        model.load_state_dict(torch.load(args.checkpoint, map_location=device))

    accuracy = evaluate(model, test_loader, device)
    print(f"final test accuracy={accuracy:.4%}")
    export_header(model.cpu(), raw_test, raw_label, args.output, accuracy)


if __name__ == "__main__":
    main()
