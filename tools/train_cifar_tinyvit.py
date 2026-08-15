#!/usr/bin/env python3
"""Train and export a larger CIFAR-10 TinyViT for the LSME FPGA demo.

The exported network keeps 8x8=64 tokens so the existing attention heatmap
and DVI interface remain usable.  Each token is a 4x4 RGB patch (K=48), and
two transformer blocks make the per-image matrix workload larger than the
Fashion-MNIST demonstration without requiring a different FPGA bitstream.
"""

from __future__ import annotations

import argparse
import math
import os
import pickle
import random
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch import nn
from torch.utils.data import DataLoader, Dataset

from train_tinyvit import (RMSNorm, choose_fraction, format_c_array,
                           linear_parameters, quantize, requant_reference,
                           rmsnorm_reference, softmax_reference)


DATA_URL = "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz"
CLASS_NAMES = [
    "airplane", "automobile", "bird", "cat", "deer",
    "dog", "frog", "horse", "ship", "truck",
]
TOKENS = 64
MODEL_DIM = 32
HEADS = 4
HEAD_DIM = 8
MLP_DIM = 64
BLOCKS = 2
PATCH_DIM = 48


def download_dataset(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    image_tree = root / "cifar10"
    if image_tree.is_dir():
        return image_tree
    archive = root / "cifar-10-python.tar.gz"
    extracted = root / "cifar-10-batches-py"
    fastai_archive = root / "cifar10.tgz"
    if fastai_archive.exists() and fastai_archive.stat().st_size > 1000000:
        print(f"extract {fastai_archive}", flush=True)
        with tarfile.open(fastai_archive, "r:gz") as stream:
            stream.extractall(root, filter="data")
        return image_tree
    if not extracted.is_dir():
        if not archive.exists() or archive.stat().st_size < 1000000:
            temporary = archive.with_suffix(".part")
            print(f"download {DATA_URL}")
            urllib.request.urlretrieve(DATA_URL, temporary)
            temporary.replace(archive)
        print(f"extract {archive}")
        with tarfile.open(archive, "r:gz") as stream:
            stream.extractall(root, filter="data")
    return extracted


def read_batch(path: Path) -> tuple[np.ndarray, np.ndarray]:
    with path.open("rb") as stream:
        content = pickle.load(stream, encoding="bytes")
    image = np.asarray(content[b"data"], dtype=np.uint8)
    label = np.asarray(content[b"labels"], dtype=np.int64)
    image = image.reshape(-1, 3, 32, 32).transpose(0, 2, 3, 1).copy()
    return image, label


def read_image_tree(root: Path, split: str) -> tuple[np.ndarray, np.ndarray]:
    images = []
    labels = []
    for class_id, name in enumerate(CLASS_NAMES):
        paths = sorted((root / split / name).glob("*.png"))
        if not paths:
            raise FileNotFoundError(f"missing {split}/{name} in {root}")
        for path in paths:
            with Image.open(path) as image:
                images.append(np.asarray(image.convert("RGB"), dtype=np.uint8).copy())
            labels.append(class_id)
    return np.stack(images), np.asarray(labels, dtype=np.int64)


def load_dataset(root: Path, limit_train: int) -> tuple[np.ndarray, ...]:
    directory = download_dataset(root)
    if (directory / "train").is_dir():
        print(f"load PNG tree {directory}", flush=True)
        train_image, train_label = read_image_tree(directory, "train")
        test_image, test_label = read_image_tree(directory, "test")
    else:
        train_images = []
        train_labels = []
        for index in range(1, 6):
            image, label = read_batch(directory / f"data_batch_{index}")
            train_images.append(image)
            train_labels.append(label)
        train_image = np.concatenate(train_images)
        train_label = np.concatenate(train_labels)
        test_image, test_label = read_batch(directory / "test_batch")
    if limit_train:
        # PNG mirror stores samples by class; use a balanced prefix for fast smoke runs.
        per_class = limit_train // len(CLASS_NAMES)
        remainder = limit_train % len(CLASS_NAMES)
        selected = []
        for class_id in range(len(CLASS_NAMES)):
            count = per_class + (1 if class_id < remainder else 0)
            selected.extend(np.flatnonzero(train_label == class_id)[:count])
        selected_index = np.asarray(selected, dtype=np.int64)
        train_image = train_image[selected_index]
        train_label = train_label[selected_index]
    return train_image, train_label, test_image, test_label


class CifarDataset(Dataset):
    def __init__(self, image: np.ndarray, label: np.ndarray, augment: bool):
        self.image = image
        self.label = label
        self.augment = augment

    def __len__(self) -> int:
        return len(self.label)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor]:
        image = torch.from_numpy(self.image[index]).permute(2, 0, 1)
        image = image.to(torch.float32).div_(255.0)
        if self.augment and torch.rand(()) < 0.5:
            image = torch.flip(image, dims=(2,))
        return image, torch.tensor(int(self.label[index]), dtype=torch.int64)


class TransformerBlock(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.norm1 = RMSNorm(MODEL_DIM)
        self.q = nn.Linear(MODEL_DIM, MODEL_DIM)
        self.k = nn.Linear(MODEL_DIM, MODEL_DIM)
        self.v = nn.Linear(MODEL_DIM, MODEL_DIM)
        self.projection = nn.Linear(MODEL_DIM, MODEL_DIM)
        self.norm2 = RMSNorm(MODEL_DIM)
        self.mlp1 = nn.Linear(MODEL_DIM, MLP_DIM)
        self.mlp2 = nn.Linear(MLP_DIM, MODEL_DIM)

    def forward(self, token: torch.Tensor,
                return_attention: bool = False) -> tuple[torch.Tensor, torch.Tensor | None]:
        batch = token.shape[0]
        normal = self.norm1(token)
        q = self.q(normal).view(batch, TOKENS, HEADS, HEAD_DIM).transpose(1, 2)
        k = self.k(normal).view(batch, TOKENS, HEADS, HEAD_DIM).transpose(1, 2)
        v = self.v(normal).view(batch, TOKENS, HEADS, HEAD_DIM).transpose(1, 2)
        attention = torch.softmax((q @ k.transpose(-1, -2)) / math.sqrt(HEAD_DIM), dim=-1)
        context = (attention @ v).transpose(1, 2).reshape(batch, TOKENS, MODEL_DIM)
        token = token + self.projection(context)
        normal = self.norm2(token)
        token = token + self.mlp2(torch.relu(self.mlp1(normal)))
        return token, attention if return_attention else None


class CifarTinyViT(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.patch = nn.Conv2d(3, MODEL_DIM, kernel_size=4, stride=4, bias=True)
        self.position = nn.Parameter(torch.zeros(1, TOKENS, MODEL_DIM))
        self.blocks = nn.ModuleList(TransformerBlock() for _ in range(BLOCKS))
        self.final_norm = RMSNorm(MODEL_DIM)
        self.classifier = nn.Linear(MODEL_DIM, 10)
        nn.init.trunc_normal_(self.position, std=0.02)

    def forward(self, image: torch.Tensor, return_attention: bool = False):
        token = self.patch(image).flatten(2).transpose(1, 2) + self.position
        attention = None
        for index, block in enumerate(self.blocks):
            token, next_attention = block(token, return_attention and index == BLOCKS - 1)
            if next_attention is not None:
                attention = next_attention
        logits = self.classifier(self.final_norm(token).mean(dim=1))
        return (logits, attention) if return_attention else logits


@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device) -> float:
    model.eval()
    correct = 0
    total = 0
    for image, label in loader:
        prediction = model(image.to(device)).argmax(dim=1).cpu()
        correct += int((prediction == label).sum())
        total += label.numel()
    return correct / total


def patch_reference(raw_image: np.ndarray) -> np.ndarray:
    pixel = np.rint(raw_image.astype(np.float64) * (127.0 / 255.0)).astype(np.int8)
    patch = pixel.reshape(-1, 8, 4, 8, 4, 3).transpose(0, 1, 3, 2, 4, 5)
    return patch.reshape(-1, TOKENS, PATCH_DIM)


def block_reference(token: np.ndarray, parameter: dict, block: int) -> tuple[np.ndarray, np.ndarray]:
    prefix = f"block{block}_"
    normal = rmsnorm_reference(token, parameter[prefix + "norm1"])
    projected = {}
    for name in ("q", "k", "v"):
        projected[name] = requant_reference(
            normal.astype(np.int32) @ parameter[prefix + name + "_w"].astype(np.int32)
            + parameter[prefix + name + "_b"], parameter[prefix + name + "_shift"])
        projected[name] = projected[name].reshape(-1, TOKENS, HEADS, HEAD_DIM).transpose(0, 2, 1, 3)
    score = projected["q"].astype(np.int32) @ projected["k"].astype(np.int32).transpose(0, 1, 3, 2)
    probability = softmax_reference(score, 6)
    context = requant_reference(
        probability.astype(np.int32) @ projected["v"].astype(np.int32), 7)
    context = context.transpose(0, 2, 1, 3).reshape(-1, TOKENS, MODEL_DIM)
    projection = requant_reference(
        context.astype(np.int32) @ parameter[prefix + "projection_w"].astype(np.int32)
        + parameter[prefix + "projection_b"], parameter[prefix + "projection_shift"])
    token = np.clip(token.astype(np.int16) + projection.astype(np.int16), -128, 127).astype(np.int8)
    normal = rmsnorm_reference(token, parameter[prefix + "norm2"])
    hidden = requant_reference(
        normal.astype(np.int32) @ parameter[prefix + "mlp1_w"].astype(np.int32)
        + parameter[prefix + "mlp1_b"], parameter[prefix + "mlp1_shift"], relu=True)
    mlp = requant_reference(
        hidden.astype(np.int32) @ parameter[prefix + "mlp2_w"].astype(np.int32)
        + parameter[prefix + "mlp2_b"], parameter[prefix + "mlp2_shift"])
    token = np.clip(token.astype(np.int16) + mlp.astype(np.int16), -128, 127).astype(np.int8)
    return token, probability


def integer_reference(raw_image: np.ndarray, parameter: dict) -> tuple[np.ndarray, np.ndarray]:
    patch = patch_reference(raw_image)
    token = requant_reference(
        patch.astype(np.int32) @ parameter["patch_w"].astype(np.int32) + parameter["patch_b"],
        parameter["patch_shift"])
    token = np.clip(token.astype(np.int16) + parameter["position"], -128, 127).astype(np.int8)
    probability = np.zeros((len(raw_image), HEADS, TOKENS, TOKENS), dtype=np.int8)
    for block in range(BLOCKS):
        token, probability = block_reference(token, parameter, block)
    final = rmsnorm_reference(token, parameter["final_norm"])
    pooled = np.rint(final.astype(np.int32).mean(axis=1)).astype(np.int8)
    logits = pooled.astype(np.int32) @ parameter["classifier_w"].astype(np.int32)
    return logits[:, :10] + parameter["classifier_b"][:10], probability


def preview_rgb332_images(raw_image: np.ndarray) -> np.ndarray:
    """Encode original-resolution 32x32 RGB images for the DVI's RGB332 bus."""
    red = raw_image[..., 0] & np.uint8(0xe0)
    green = (raw_image[..., 1] & np.uint8(0xe0)) >> np.uint8(3)
    blue = raw_image[..., 2] >> np.uint8(6)
    return (red | green | blue).astype(np.uint8)


def quantized_linear(layer: nn.Linear, input_fraction: int, output_fraction: int,
                     padded_outputs: int | None = None) -> tuple[np.ndarray, ...]:
    return linear_parameters(layer, input_fraction, output_fraction, padded_outputs)


def export_header(model: CifarTinyViT, raw_test: np.ndarray, test_label: np.ndarray,
                  output: Path, float_accuracy: float, integer_samples: int) -> None:
    frac_input = 7
    frac_token = 5
    frac_qkv = 5
    frac_context = 5
    frac_hidden = 4
    frac_final = 5
    patch_weight = model.patch.weight.detach().cpu().numpy().transpose(0, 2, 3, 1)
    patch_weight = patch_weight.reshape(MODEL_DIM, PATCH_DIM).T
    patch_bias = model.patch.bias.detach().cpu().numpy()
    patch_weight_fraction = choose_fraction(patch_weight)
    patch_weight_q = quantize(patch_weight, patch_weight_fraction)
    patch_bias_q = quantize(patch_bias, frac_input + patch_weight_fraction, np.int32)
    patch_shift = frac_input + patch_weight_fraction - frac_token
    if patch_shift < 0 or patch_shift > 31:
        raise ValueError(f"unsupported patch shift {patch_shift}")

    parameter: dict[str, np.ndarray | int] = {
        "patch_w": patch_weight_q,
        "patch_b": patch_bias_q,
        "patch_shift": patch_shift,
        "position": quantize(model.position.detach().cpu().numpy()[0], frac_token),
        "final_norm": quantize(model.final_norm.weight.detach().cpu().numpy(), 6),
    }
    arrays = [
        format_c_array("tinyvit_patch_weight", patch_weight_q, "int8_t"),
        format_c_array("tinyvit_patch_bias", patch_bias_q, "int32_t", 8),
        format_c_array("tinyvit_position", parameter["position"], "int8_t"),
    ]
    constants: dict[str, int] = {
        "TINYVIT_FRAC_INPUT": frac_input,
        "TINYVIT_FRAC_TOKEN": frac_token,
        "TINYVIT_FRAC_QKV": frac_qkv,
        "TINYVIT_FRAC_CONTEXT": frac_context,
        "TINYVIT_FRAC_HIDDEN": frac_hidden,
        "TINYVIT_FRAC_FINAL": frac_final,
        "TINYVIT_NORM_GAIN_FRAC": 6,
        "TINYVIT_PATCH_SHIFT": patch_shift,
        "TINYVIT_ATTENTION_SCORE_SHIFT": 6,
        "TINYVIT_CONTEXT_SHIFT": 7,
    }
    for index, block in enumerate(model.blocks):
        prefix = f"block{index}_"
        c_prefix = f"tinyvit_block{index}_"
        parameter[prefix + "norm1"] = quantize(block.norm1.weight.detach().cpu().numpy(), 6)
        parameter[prefix + "norm2"] = quantize(block.norm2.weight.detach().cpu().numpy(), 6)
        arrays.append(format_c_array(c_prefix + "norm1_gain", parameter[prefix + "norm1"], "int8_t"))
        for name in ("q", "k", "v"):
            weight, bias, weight_fraction, shift = quantized_linear(
                getattr(block, name), frac_token, frac_qkv)
            parameter[prefix + name + "_w"] = weight
            parameter[prefix + name + "_b"] = bias
            parameter[prefix + name + "_shift"] = shift
            constants[f"TINYVIT_BLOCK{index}_{name.upper()}_SHIFT"] = shift
            arrays.extend([
                format_c_array(c_prefix + name + "_weight", weight, "int8_t"),
                format_c_array(c_prefix + name + "_bias", bias, "int32_t", 8),
            ])
            print(f"block{index} {name} weight_fraction={weight_fraction} shift={shift}")
        for name, layer, in_fraction, out_fraction, relu in (
            ("projection", block.projection, frac_context, frac_token, False),
            ("mlp1", block.mlp1, frac_token, frac_hidden, True),
            ("mlp2", block.mlp2, frac_hidden, frac_token, False),
        ):
            weight, bias, weight_fraction, shift = quantized_linear(layer, in_fraction, out_fraction)
            parameter[prefix + name + "_w"] = weight
            parameter[prefix + name + "_b"] = bias
            parameter[prefix + name + "_shift"] = shift
            constants[f"TINYVIT_BLOCK{index}_{name.upper()}_SHIFT"] = shift
            arrays.extend([
                format_c_array(c_prefix + name + "_weight", weight, "int8_t"),
                format_c_array(c_prefix + name + "_bias", bias, "int32_t", 8),
            ])
            print(f"block{index} {name} weight_fraction={weight_fraction} shift={shift} relu={relu}")
        arrays.append(format_c_array(c_prefix + "norm2_gain", parameter[prefix + "norm2"], "int8_t"))

    classifier_weight, classifier_bias, classifier_weight_fraction, _ = quantized_linear(
        model.classifier, frac_final, 0, padded_outputs=12)
    parameter["classifier_w"] = classifier_weight
    parameter["classifier_b"] = classifier_bias
    constants["TINYVIT_CLASSIFIER_ACC_FRAC"] = frac_final + classifier_weight_fraction
    arrays.extend([
        format_c_array("tinyvit_final_norm_gain", parameter["final_norm"], "int8_t"),
        format_c_array("tinyvit_classifier_weight", classifier_weight, "int8_t"),
        format_c_array("tinyvit_classifier_bias", classifier_bias, "int32_t", 8),
    ])

    # Choose deterministic, high-margin, integer-correct CIFAR-10 images for the live demo.
    examples = []
    labels = []
    indices = []
    for class_id in range(10):
        candidates = np.flatnonzero(test_label == class_id)[:512]
        logits, _ = integer_reference(raw_test[candidates], parameter)
        good = logits.argmax(axis=1) == class_id
        if not good.any():
            raise RuntimeError(f"no integer-correct CIFAR-10 demo image for class {class_id}")
        margin = np.partition(logits[good], -2, axis=1)[:, -1] - np.partition(logits[good], -2, axis=1)[:, -2]
        chosen = candidates[good][int(margin.argmax())]
        examples.append(raw_test[chosen])
        labels.append(class_id)
        indices.append(int(chosen))
    examples_np = np.stack(examples)
    demo_logits, _ = integer_reference(examples_np, parameter)
    preview_rgb332 = preview_rgb332_images(examples_np)

    limit = min(integer_samples, len(raw_test))
    integer_correct = 0
    for start in range(0, limit, 100):
        logits, _ = integer_reference(raw_test[start:start + 100], parameter)
        integer_correct += int((logits.argmax(axis=1) == test_label[start:start + 100]).sum())
    integer_accuracy = integer_correct / limit
    constants["TINYVIT_FLOAT_TEST_ACCURACY_X10000"] = round(float_accuracy * 10000)
    constants["TINYVIT_INTEGER_TEST_ACCURACY_X10000"] = round(integer_accuracy * 10000)
    constants["TINYVIT_INTEGER_EVAL_SAMPLES"] = limit
    arrays.extend([
        format_c_array("tinyvit_demo_images", examples_np, "uint8_t", 24),
        format_c_array("tinyvit_demo_preview_rgb332", preview_rgb332, "uint8_t", 32),
        format_c_array("tinyvit_demo_labels", np.asarray(labels, dtype=np.uint8), "uint8_t", 10),
        format_c_array("tinyvit_demo_indices", np.asarray(indices, dtype=np.uint16), "uint16_t", 10),
        format_c_array("tinyvit_demo_expected_logits", demo_logits, "int32_t", 10),
    ])

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as stream:
        stream.write("#ifndef CIFAR_TINYVIT_MODEL_H\n#define CIFAR_TINYVIT_MODEL_H\n\n#include <stdint.h>\n\n")
        for name, value in constants.items():
            stream.write(f"#define {name} {value}\n")
        stream.write("\n")
        for array in arrays:
            stream.write(array + "\n\n")
        names = ", ".join('"' + name + '"' for name in CLASS_NAMES)
        stream.write(f"static const char *const tinyvit_class_names[10] = {{{names}}};\n\n#endif\n")
    print(f"wrote {output} ({output.stat().st_size / 1024:.1f} KiB)")
    print(f"float accuracy={float_accuracy:.4%}")
    print(f"integer accuracy ({limit} samples)={integer_accuracy:.4%}")
    print("demo test indices:", indices)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path("tools/.cache/cifar-10"))
    parser.add_argument("--output", type=Path,
                        default=Path("sdk/software/examples/cifar_tinyvit_demo/cifar_tinyvit_model.h"))
    parser.add_argument("--checkpoint", type=Path, default=Path("tools/cifar_tinyvit_2block.pt"))
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--limit-train", type=int, default=0)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--learning-rate", type=float, default=2e-3)
    parser.add_argument("--integer-eval-samples", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=20260814)
    parser.add_argument("--load-checkpoint", action="store_true")
    args = parser.parse_args()

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.set_num_threads(max(1, min(12, os.cpu_count() or 1)))
    train_image, train_label, test_image, test_label = load_dataset(args.data_dir, args.limit_train)
    train_loader = DataLoader(CifarDataset(train_image, train_label, augment=True),
                              batch_size=args.batch_size, shuffle=True, num_workers=0)
    test_loader = DataLoader(CifarDataset(test_image, test_label, augment=False),
                             batch_size=args.batch_size * 2, num_workers=0)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"device={device}, train={len(train_label)}, test={len(test_label)}")
    model = CifarTinyViT().to(device)
    if args.load_checkpoint and args.checkpoint.exists():
        model.load_state_dict(torch.load(args.checkpoint, map_location=device, weights_only=True))
    else:
        optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-3)
        scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=max(1, args.epochs))
        best = -1.0
        for epoch in range(1, args.epochs + 1):
            model.train()
            loss_total = 0.0
            count = 0
            for image, label in train_loader:
                image = image.to(device)
                label = label.to(device)
                optimizer.zero_grad(set_to_none=True)
                loss = nn.functional.cross_entropy(model(image), label)
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                loss_total += float(loss.detach()) * label.numel()
                count += label.numel()
            scheduler.step()
            accuracy = evaluate(model, test_loader, device)
            print(f"epoch={epoch:02d} loss={loss_total / count:.4f} test={accuracy:.4%}", flush=True)
            if accuracy >= best:
                best = accuracy
                args.checkpoint.parent.mkdir(parents=True, exist_ok=True)
                torch.save(model.state_dict(), args.checkpoint)
        model.load_state_dict(torch.load(args.checkpoint, map_location=device, weights_only=True))
    accuracy = evaluate(model, test_loader, device)
    export_header(model.cpu(), test_image, test_label, args.output, accuracy,
                  args.integer_eval_samples)


if __name__ == "__main__":
    main()
