"""Spectral Audio recurrent gain predictor."""
import torch
from torch import nn


class GainPredictor(nn.Module):
    def __init__(self, hidden=128):
        super().__init__()
        self.gru = nn.GRU(64, hidden, batch_first=True)
        self.head = nn.Linear(hidden, 64)

    def forward(self, features, state):
        output, state = self.gru(features, state)
        return self.head(output), state
