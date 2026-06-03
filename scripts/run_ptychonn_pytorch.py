#!/usr/bin/env python3
import argparse
import json
import math
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from skimage.transform import resize
from sklearn.utils import shuffle
from torch.utils.data import DataLoader, TensorDataset, random_split
from tqdm import tqdm


H = 64
W = 64
NCONV = 32


class ReconModel(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Conv2d(1, NCONV, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV, NCONV, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.MaxPool2d((2, 2)),
            nn.Conv2d(NCONV, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 2, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.MaxPool2d((2, 2)),
            nn.Conv2d(NCONV * 2, NCONV * 4, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 4, NCONV * 4, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.MaxPool2d((2, 2)),
        )
        self.decoder_amp = nn.Sequential(
            nn.Conv2d(NCONV * 4, NCONV * 4, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 4, NCONV * 4, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Upsample(scale_factor=2, mode="bilinear"),
            nn.Conv2d(NCONV * 4, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 2, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Upsample(scale_factor=2, mode="bilinear"),
            nn.Conv2d(NCONV * 2, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 2, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Upsample(scale_factor=2, mode="bilinear"),
            nn.Conv2d(NCONV * 2, 1, 3, stride=1, padding=(1, 1)),
            nn.Sigmoid(),
        )
        self.decoder_phase = nn.Sequential(
            nn.Conv2d(NCONV * 4, NCONV * 4, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 4, NCONV * 4, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Upsample(scale_factor=2, mode="bilinear"),
            nn.Conv2d(NCONV * 4, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 2, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Upsample(scale_factor=2, mode="bilinear"),
            nn.Conv2d(NCONV * 2, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Conv2d(NCONV * 2, NCONV * 2, 3, stride=1, padding=(1, 1)),
            nn.ReLU(),
            nn.Upsample(scale_factor=2, mode="bilinear"),
            nn.Conv2d(NCONV * 2, 1, 3, stride=1, padding=(1, 1)),
            nn.Tanh(),
        )

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        encoded = self.encoder(x)
        amp = self.decoder_amp(encoded)
        phase = self.decoder_phase(encoded) * math.pi
        return amp, phase


def prepare_dataloaders(args: argparse.Namespace) -> tuple[DataLoader, DataLoader, dict]:
    diff = np.load(args.diff_npz)["arr_0"]
    real_space = np.load(args.labels_npy, mmap_mode="r")
    train_lines = min(args.train_lines, diff.shape[0], real_space.shape[0])
    train_count = train_lines * diff.shape[1]

    resized = np.zeros((train_lines, diff.shape[1], H, W), dtype=np.float32)
    for i in tqdm(range(train_lines), desc="resize diffraction lines"):
        for j in range(diff.shape[1]):
            crop = diff[i, j, 32:-32, 32:-32]
            item = resize(crop, (H, W), preserve_range=True, anti_aliasing=True).astype(np.float32)
            resized[i, j] = np.where(item < 3, 0, item)

    amp = np.abs(real_space[:train_lines]).astype(np.float32)
    phase = np.angle(real_space[:train_lines]).astype(np.float32)

    x_train = resized.reshape(-1, H, W)[:, np.newaxis, :, :]
    y_amp = amp.reshape(-1, H, W)[:, np.newaxis, :, :]
    y_phase = phase.reshape(-1, H, W)[:, np.newaxis, :, :]
    x_train, y_amp, y_phase = shuffle(x_train, y_amp, y_phase, random_state=0)

    dataset = TensorDataset(torch.from_numpy(x_train), torch.from_numpy(y_amp), torch.from_numpy(y_phase))
    valid_count = min(args.valid_count, len(dataset) // 5)
    train_dataset, valid_dataset = random_split(
        dataset,
        [len(dataset) - valid_count, valid_count],
        generator=torch.Generator().manual_seed(0),
    )

    loader_args = {
        "batch_size": args.batch_size,
        "num_workers": args.num_workers,
        "pin_memory": False,
    }
    metadata = {
        "diff_shape": list(diff.shape),
        "labels_shape": list(real_space.shape),
        "train_lines": train_lines,
        "train_samples": train_count,
        "train_dataset": len(train_dataset),
        "valid_dataset": len(valid_dataset),
    }
    return (
        DataLoader(train_dataset, shuffle=True, **loader_args),
        DataLoader(valid_dataset, shuffle=False, **loader_args),
        metadata,
    )


def run_epoch(model: nn.Module, loader: DataLoader, device: torch.device, optimizer, criterion) -> list[float]:
    model.train()
    total = amp_total = phase_total = 0.0
    batches = 0
    for x, amp, phase in tqdm(loader, desc="train batches"):
        x = x.to(device)
        amp = amp.to(device)
        phase = phase.to(device)
        pred_amp, pred_phase = model(x)
        amp_loss = criterion(pred_amp, amp)
        phase_loss = criterion(pred_phase, phase)
        loss = amp_loss + phase_loss
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        total += float(loss.detach())
        amp_total += float(amp_loss.detach())
        phase_total += float(phase_loss.detach())
        batches += 1
    return [total / batches, amp_total / batches, phase_total / batches]


def validate(model: nn.Module, loader: DataLoader, device: torch.device, criterion) -> list[float]:
    model.eval()
    total = amp_total = phase_total = 0.0
    batches = 0
    with torch.no_grad():
        for x, amp, phase in tqdm(loader, desc="valid batches"):
            x = x.to(device)
            amp = amp.to(device)
            phase = phase.to(device)
            pred_amp, pred_phase = model(x)
            amp_loss = criterion(pred_amp, amp)
            phase_loss = criterion(pred_phase, phase)
            total += float(amp_loss + phase_loss)
            amp_total += float(amp_loss)
            phase_total += float(phase_loss)
            batches += 1
    return [total / batches, amp_total / batches, phase_total / batches]


def run_inference(model: nn.Module, args: argparse.Namespace, device: torch.device, out_dir: Path) -> dict:
    x_test = np.load(args.x_test_npy, mmap_mode="r")
    limit = min(args.test_limit, x_test.shape[0]) if args.test_limit else x_test.shape[0]
    x = np.asarray(x_test[:limit]).reshape(-1, H, W, 1).transpose(0, 3, 1, 2).astype(np.float32)
    loader = DataLoader(TensorDataset(torch.from_numpy(x)), batch_size=args.batch_size, shuffle=False)

    model.eval()
    amps = []
    phases = []
    with torch.no_grad():
        for (batch,) in tqdm(loader, desc="inference batches"):
            pred_amp, pred_phase = model(batch.to(device))
            amps.append(pred_amp.cpu().numpy())
            phases.append(pred_phase.cpu().numpy())

    amp_arr = np.concatenate(amps, axis=0).astype(np.float32)
    phase_arr = np.concatenate(phases, axis=0).astype(np.float32)
    out_file = out_dir / "test_predictions.npz"
    np.savez_compressed(out_file, amp=amp_arr, phase=phase_arr)
    return {
        "test_samples": limit,
        "prediction_file": str(out_file),
        "prediction_bytes": out_file.stat().st_size,
        "amp_shape": list(amp_arr.shape),
        "phase_shape": list(phase_arr.shape),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Native PyTorch PtychoNN training/inference run")
    parser.add_argument("--diff-npz", required=True)
    parser.add_argument("--labels-npy", required=True)
    parser.add_argument("--x-test-npy", required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--epochs", type=int, default=1)
    parser.add_argument("--train-lines", type=int, default=100)
    parser.add_argument("--valid-count", type=int, default=805)
    parser.add_argument("--test-limit", type=int, default=3600)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--num-workers", type=int, default=4)
    parser.add_argument("--threads", type=int, default=0)
    args = parser.parse_args()

    if args.threads:
        torch.set_num_threads(args.threads)

    run_dir = Path(args.run_dir).resolve()
    out_dir = run_dir / "outputs"
    out_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()

    train_loader, valid_loader, data_meta = prepare_dataloaders(args)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = ReconModel().to(device)
    criterion = nn.L1Loss()
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)

    metrics = []
    best_valid = float("inf")
    for epoch in range(args.epochs):
        train_loss = run_epoch(model, train_loader, device, optimizer, criterion)
        valid_loss = validate(model, valid_loader, device, criterion)
        if valid_loss[0] < best_valid:
            best_valid = valid_loss[0]
            torch.save(model.state_dict(), out_dir / "best_model_state.pt")
        metrics.append({"epoch": epoch, "train_loss": train_loss, "valid_loss": valid_loss})
        print(json.dumps(metrics[-1], sort_keys=True))

    inference = run_inference(model, args, device, out_dir)
    manifest = {
        "workflow": "PtychoNN",
        "runner": "PyTorch",
        "device": str(device),
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "num_workers": args.num_workers,
        "data": data_meta,
        "metrics": metrics,
        "inference": inference,
        "elapsed_seconds": time.time() - started,
    }
    manifest_path = run_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True))
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
