#!/usr/bin/env python3
"""Tokenize prompt text for OpenAI CLIP ViT-B/32 using only Python's standard library."""

import json
import re
import sys
from pathlib import Path

CONTEXT_LENGTH = 77
TOKEN_PATTERN = re.compile(
    r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|"
    r"[^\W\d_]+|\d|(?:[^\s\w]|_)+",
    re.IGNORECASE,
)


def byte_to_unicode():
    values = list(range(ord("!"), ord("~") + 1))
    values += list(range(ord("¡"), ord("¬") + 1))
    values += list(range(ord("®"), ord("ÿ") + 1))
    characters = values[:]
    initial = set(values)
    extra = 0
    for value in range(256):
        if value not in initial:
            values.append(value)
            characters.append(256 + extra)
            extra += 1
    return {value: chr(character) for value, character in zip(values, characters)}


class Tokenizer:
    def __init__(self, vocab_path: Path, merges_path: Path):
        self.vocab = json.loads(vocab_path.read_text(encoding="utf-8"))
        self.byte_mapping = byte_to_unicode()
        lines = merges_path.read_text(encoding="utf-8").splitlines()
        self.ranks = {tuple(line.split()): index for index, line in enumerate(lines[1:])}
        self.cache = {}

    def bpe(self, token: str):
        if token in self.cache:
            return self.cache[token]
        pieces = list(token)
        pieces[-1] += "</w>"
        while len(pieces) > 1:
            pairs = zip(pieces, pieces[1:])
            ranked = [(self.ranks[pair], pair) for pair in pairs if pair in self.ranks]
            if not ranked:
                break
            _, best = min(ranked)
            merged = []
            index = 0
            while index < len(pieces):
                if index + 1 < len(pieces) and (pieces[index], pieces[index + 1]) == best:
                    merged.append(pieces[index] + pieces[index + 1])
                    index += 2
                else:
                    merged.append(pieces[index])
                    index += 1
            pieces = merged
        self.cache[token] = pieces
        return pieces

    def encode(self, text: str):
        ids = [self.vocab["<|startoftext|>"]]
        for match in TOKEN_PATTERN.findall(text.lower()):
            encoded = "".join(self.byte_mapping[byte] for byte in match.encode("utf-8"))
            for piece in self.bpe(encoded):
                ids.append(self.vocab[piece])
        if len(ids) >= CONTEXT_LENGTH:
            raise ValueError(f"Prompt exceeds CLIP's 75-token limit: {text!r}")
        ids.append(self.vocab["<|endoftext|>"])
        return ids + [0] * (CONTEXT_LENGTH - len(ids))


def main():
    prompts_file = Path(sys.argv[1])
    output_file = Path(sys.argv[2])
    tools_dir = Path(__file__).resolve().parent
    tokenizer = Tokenizer(tools_dir / "clip-vocab.json", tools_dir / "clip-merges.txt")
    prompts = json.loads(prompts_file.read_text(encoding="utf-8"))
    result = {}
    for name in ("positive", "negative"):
        texts = prompts[name + "Prompts"]
        if not texts or not all(isinstance(text, str) and text.strip() for text in texts):
            raise ValueError(f"{name}Prompts must contain at least one nonempty description")
        result[name + "Prompts"] = texts
        result[name + "Tokens"] = [tokenizer.encode(text) for text in texts]
    output_file.write_text(json.dumps(result), encoding="utf-8")


if __name__ == "__main__":
    main()
