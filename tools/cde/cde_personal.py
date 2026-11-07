#!/usr/bin/env python3
"""Experimental reader-specific prediction using CDE/ADF book profiles.

This tool is not connected to the app and is not a calibrated time model.
Each input session is a measured, contiguous reading segment with a known word
count and measured active seconds. IDs are local pseudonyms; book IDs are the
content digests used by cde_sheet. Inputs and outputs stay on the caller's disk.

Usage:
    python3 tools/cde/cde_personal.py predict --scores SCORES.json --sessions SESSIONS.json \
        --reader READER_ID --book BOOK_DIGEST --words 10000 --as-of 2026-10-29T12:00:00Z
    python3 tools/cde/cde_personal.py evaluate --scores SCORES.json --sessions SESSIONS.json

Sessions are a JSON array of objects with id, reader_id, book_id, start, end,
words_read and active_seconds. start/end must include a time zone. Word counts
and active time must be observed rather than inferred from page numbers. A
session's score is a book-level approximation, not its passage's difficulty.
The evaluator predicts each segment using only sessions ended before its start.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import statistics

import cde_model

DIMENSIONS = cde_model.DIMENSIONS
MODEL_VERSION = "cde-personal/experimental-1"


def parse_time(value):
    if not isinstance(value, str):
        raise ValueError("timestamps must be ISO 8601 strings with a time zone")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("timestamps must be ISO 8601 strings with a time zone") from exc
    if result.tzinfo is None or result.utcoffset() is None:
        raise ValueError("timestamps must include a time zone")
    return result.astimezone(timezone.utc)


def positive_number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a positive finite number")
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be a positive finite number")
    return float(value)


def load_sessions(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError("sessions must be a JSON array")
    sessions, seen = [], set()
    for row in data:
        if not isinstance(row, dict):
            raise ValueError("each session must be an object")
        identifiers = [row.get(k) for k in ("id", "reader_id", "book_id")]
        if any(not isinstance(x, str) or not x.strip() for x in identifiers):
            raise ValueError("session id, reader_id and book_id must be nonempty strings")
        if identifiers[0] in seen:
            raise ValueError(f"duplicate session id: {identifiers[0]}")
        seen.add(identifiers[0])
        start, end = parse_time(row.get("start")), parse_time(row.get("end"))
        words = positive_number(row.get("words_read"), "words_read")
        seconds = positive_number(row.get("active_seconds"), "active_seconds")
        if end <= start or seconds > (end - start).total_seconds():
            raise ValueError(f"session {identifiers[0]} has inconsistent time bounds")
        sessions.append({"id": identifiers[0], "reader_id": identifiers[1],
                         "book_id": identifiers[2], "start": start, "end": end,
                         "words_read": words, "active_seconds": seconds})
    return sorted(sessions, key=lambda r: (r["start"], r["id"]))


def load_profiles(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    summary = data.get("summary") if isinstance(data, dict) else None
    if not isinstance(summary, dict) or summary.get("formula") != cde_model.FORMULA_ID:
        raise ValueError("expected a cde_sheet scores file for the current ADF version")
    if not isinstance(data.get("rows"), list):
        raise ValueError("scores file must contain rows")
    profiles = {}
    for row in data["rows"]:
        if not isinstance(row, dict):
            raise ValueError("each scores row must be an object")
        if row.get("status") != "ok":
            continue
        digest, dimensions = row.get("digest"), row.get("dimensions")
        if not isinstance(digest, str) or not digest or not isinstance(dimensions, dict):
            raise ValueError("scored rows must contain digest and dimensions")
        if set(dimensions) != set(DIMENSIONS):
            raise ValueError(f"incomplete ADF dimensions for {digest}")
        for value in dimensions.values():
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError(f"invalid ADF dimension for {digest}")
        if digest in profiles and profiles[digest] != dimensions:
            raise ValueError(f"conflicting scores for digest {digest}")
        profiles[digest] = dimensions
    return profiles


def pace(rows):
    """Aggregate measured seconds divided by measured words, not a mean of rates."""
    if not rows:
        return None
    return sum(r["active_seconds"] for r in rows) / sum(r["words_read"] for r in rows)


def predict(sessions, profiles, reader_id, book_id, words, as_of):
    words = positive_number(words, "words")
    cutoff = parse_time(as_of) if isinstance(as_of, str) else as_of
    if cutoff.tzinfo is None or cutoff.utcoffset() is None:
        raise ValueError("as_of must include a time zone")
    history = [s for s in sessions if s["reader_id"] == reader_id and s["end"] < cutoff]
    baseline = pace(history)
    if baseline is None:
        return {"status": "insufficient_reader_history", "baseline_seconds": None,
                "candidate_seconds": None, "history_sessions": 0}

    same_book = [s for s in history if s["book_id"] == book_id]
    if same_book:
        candidate = pace(same_book)
        source = "same_book"
        source_book = book_id
    elif book_id in profiles:
        # Candidate only: use the reader's closest observed book by Euclidean
        # distance across six ADF percentiles. Do not convert the ADF score to
        # a time multiplier or invent weights for its effect on reading time.
        other_ids = {s["book_id"] for s in history if s["book_id"] in profiles}
        if other_ids:
            target = profiles[book_id]
            def distance(other):
                return sum((target[d] - profiles[other][d]) ** 2 for d in DIMENSIONS)
            source_book = min(other_ids, key=lambda other: (distance(other), other))
            candidate = pace([s for s in history if s["book_id"] == source_book])
            source = "nearest_adf_profile"
        else:
            candidate, source, source_book = baseline, "reader_baseline", None
    else:
        candidate, source, source_book = baseline, "reader_baseline", None
    return {
        "status": "experimental", "model_version": MODEL_VERSION,
        "formula": cde_model.FORMULA_ID, "reader_id": reader_id, "book_id": book_id,
        "words": words, "as_of": cutoff.astimezone(timezone.utc).isoformat(),
        "history_sessions": len(history), "baseline_seconds": words * baseline,
        "candidate_seconds": words * candidate, "candidate_source": source,
        "candidate_source_book": source_book,
        "disclosure": "Experimental; no reading-time accuracy or interval has been validated.",
    }


def evaluate(sessions, profiles):
    predictions = []
    for session in sessions:
        result = predict(sessions, profiles, session["reader_id"], session["book_id"],
                         session["words_read"], session["start"])
        if result["baseline_seconds"] is None:
            continue
        predictions.append({"id": session["id"], "actual_seconds": session["active_seconds"],
                            "baseline_seconds": result["baseline_seconds"],
                            "candidate_seconds": result["candidate_seconds"],
                            "candidate_source": result["candidate_source"]})

    def metrics(key, rows):
        if not rows:
            return None
        errors = [r[key] - r["actual_seconds"] for r in rows]
        return {"mean_absolute_error_seconds": statistics.mean(map(abs, errors)),
                "median_absolute_error_seconds": statistics.median(map(abs, errors)),
                "mean_signed_error_seconds": statistics.mean(errors)}

    candidate_rows = [r for r in predictions if r["candidate_source"] == "nearest_adf_profile"]
    by_source = {
        source: {"count": len(rows), "baseline": metrics("baseline_seconds", rows),
                 "candidate": metrics("candidate_seconds", rows)}
        for source in ("same_book", "nearest_adf_profile", "reader_baseline")
        for rows in [[r for r in predictions if r["candidate_source"] == source]]
    }
    return {"model_version": MODEL_VERSION, "formula": cde_model.FORMULA_ID,
            "sessions": len(sessions), "evaluated": len(predictions),
            "skipped_no_prior_history": len(sessions) - len(predictions),
            "overall": {"baseline": metrics("baseline_seconds", predictions),
                        "candidate": metrics("candidate_seconds", predictions)},
            "adf_matched": {"count": len(candidate_rows),
                            "baseline": metrics("baseline_seconds", candidate_rows),
                            "candidate": metrics("candidate_seconds", candidate_rows)},
            "by_source": by_source,
            "predictions": predictions,
            "disclosure": "Chronological within-reader evaluation on supplied segments; not independent-reader or independent-book validation."}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("predict", "evaluate"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--scores", required=True)
        cmd.add_argument("--sessions", required=True)
        if name == "predict":
            cmd.add_argument("--reader", required=True)
            cmd.add_argument("--book", required=True)
            cmd.add_argument("--words", type=float, required=True)
            cmd.add_argument("--as-of", required=True)
    args = parser.parse_args()
    try:
        profiles = load_profiles(args.scores)
        sessions = load_sessions(args.sessions)
        result = (predict(sessions, profiles, args.reader, args.book, args.words, args.as_of)
                  if args.command == "predict" else evaluate(sessions, profiles))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(2, f"error: {exc}\n")
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
