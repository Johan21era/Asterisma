"""Per-window feature extraction for the CDE.

Six dimensions are implemented. Each returns raw, unnormalised statistics; the
model normalises them against a frozen reference distribution.

Implemented (with reliability class from PHASE-1-AUDIT.md §8.2):
  A  lexical load            B-class proxy  (no frequency norm in repo)
  B  syntactic load          B-class
  G  entity interaction      B-class
  H  continuity              B-class
  I  information density     B-class
  K  dialogue                B-class

Deliberately absent: semantic complexity, information withholding, prior
knowledge and structural memory. They need resources this repository does not
have, and a proxy would be a number with no meaning. They are listed as future
dimensions, not faked here.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from cde_text import (
    ABSTRACT_SUFFIXES,
    BE_FORMS,
    COORDINATORS,
    MORPH_SUFFIXES,
    PRONOUNS,
    SAID_VERBS,
    SHIFT_MARKERS,
    STOPWORDS,
    SUBORDINATORS,
    capitalised_runs,
    is_prose,
    quote_spans,
    raw_words,
    split_paragraphs,
    split_sentences,
    syllables,
    words,
)

STRUCTURAL = {
    "chapter", "part", "book", "volume", "prologue", "epilogue", "contents",
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "first", "second", "third", "mr", "mrs", "ms",
    "dr", "sir", "madam", "lord", "lady", "captain", "professor",
}

_NON_NAME_LOWER = STOPWORDS | STRUCTURAL | set(s.lower() for s in PRONOUNS)


def _variants(token):
    """Candidate lemma forms for a crude lexicon lookup."""
    t = token
    out = {t}
    for _ in range(2):
        if t.endswith("'s") or t.endswith("’s"):
            t = t[:-2]
            out.add(t)
        for suf, rep in (("ies", "y"), ("ses", "s"), ("es", ""), ("s", ""),
                         ("ed", ""), ("ed", "e"), ("ing", ""), ("ing", "e"),
                         ("ly", ""), ("er", ""), ("est", "")):
            if t.endswith(suf) and len(t) - len(suf) >= 3:
                out.add(t[: -len(suf)] + rep)
    return out


DEFAULT_LEXICON = Path(__file__).resolve().parent / "config" / "lexicon-v1.json"


class Lexicon:
    """Familiar-word set for the lexical dimension.

    Primary source is a **corpus frequency list**: the top N word forms by
    count across the reference corpus's sampled windows, frozen at calibration
    time (`config/lexicon-v1.json`). A word outside that list is rare *for this
    reading domain*, which is the quantity the dimension wants.

    The system dictionary is only a fallback. It is a 20th-century word list
    with no usage counts, and using it as the primary oracle systematically
    penalised modern prose: light novels scored as hard as Dostoevsky because
    words like `okay` and `jeans` were absent from it.
    """

    def __init__(self, path=None):
        self.mode = "frequency"
        self.words = set()
        target = Path(path) if path else DEFAULT_LEXICON
        try:
            payload = json.loads(target.read_text())
            self.words = set(payload["top"])
            self.corpus_tokens = payload.get("corpus_tokens", 0)
            return
        except (OSError, ValueError, KeyError):
            pass

        self.mode = "dictionary"
        try:
            with open("/usr/share/dict/words", "r", encoding="utf-8",
                      errors="ignore") as handle:
                self.words = {line.strip().lower() for line in handle if line.strip()}
        except OSError:
            self.words = set()

    def knows(self, token):
        if not self.words:
            return True
        for candidate in _variants(token):
            if candidate in self.words:
                return True
        return False


LEXICON = None


def lexicon():
    global LEXICON
    if LEXICON is None:
        LEXICON = Lexicon()
    return LEXICON


def reset_lexicon():
    """Force a re-read; used after the frequency list is rebuilt."""
    global LEXICON
    LEXICON = None


def _sentences(text):
    return [s for s in split_sentences(text) if s.strip()]


def _content(tokens):
    return [t for t in tokens if t not in STOPWORDS and len(t) > 1]


def _names(text, tokens):
    """Capitalised tokens that are not function words or structural labels."""
    found = set()
    for idx, token in capitalised_runs(text):
        low = token.lower()
        if low in _NON_NAME_LOWER:
            continue
        if len(token) < 2:
            continue
        # A capitalised token at the very start of a sentence is only a name if
        # it recurs; sentence-initial capitals are otherwise ambiguous.
        if idx < 3 and low not in _NON_NAME_LOWER:
            found.add(token)
            continue
        found.add(token)
    return found


def window_features(text):
    """Raw features for one window. No normalisation, no weights."""
    toks = words(text)
    if len(toks) < 50 or not is_prose(text):
        return None

    sents = _sentences(text)
    paras = split_paragraphs(text)
    content = _content(toks)
    lex = lexicon()

    # --- A. lexical load ---------------------------------------------------
    # Proper nouns are excluded from the rarity count: a fantasy novel is not
    # harder because it names places the dictionary has never seen. Counting
    # them made Bleach and Fire & Blood the most "difficult" books in the
    # corpus purely because of invented names.
    name_forms = {n.lower() for n in _names(text, toks)}
    lexical = [t for t in content if t not in name_forms]
    oov = sum(1 for t in lexical if not lex.knows(t))
    oov_rate = oov / max(1, len(lexical))
    morph = sum(
        1 for t in content if any(t.endswith(s) for s in MORPH_SUFFIXES)
    ) / max(1, len(content))
    abstract = sum(
        1 for t in content if any(t.endswith(s) for s in ABSTRACT_SUFFIXES)
    ) / max(1, len(content))

    # --- B. syntactic load -------------------------------------------------
    mean_sentence = len(toks) / max(1, len(sents))
    clause_marks = 0.0
    passive = 0
    lower = [t for t in toks]
    for i, token in enumerate(lower):
        if token in SUBORDINATORS or token in COORDINATORS:
            clause_marks += 1
        if token in BE_FORMS:
            for follower in lower[i + 1:i + 4]:
                if len(follower) > 4 and follower.endswith(("ed", "en")):
                    passive += 1
                    break
    clause_density = clause_marks / max(1, len(sents))
    pronoun_rate = sum(1 for t in toks if t in PRONOUNS) / max(1, len(toks))
    passive_rate = passive / max(1, len(sents))

    # --- G. entity interaction --------------------------------------------
    names = _names(text, toks)
    name_rate = len(names) / max(1, len(toks) / 100.0)
    pairs, present = 0, 0
    for sent in sents:
        sent_names = {n.lower() for n in _names(sent, words(sent))}
        k = len(sent_names)
        if k >= 2:
            present += 1
            pairs += k * (k - 1) / 2
    cooc = pairs / max(1, len(sents))

    # --- H. continuity -----------------------------------------------------
    overlaps = []
    prev_content = None
    for para in paras:
        cur = {t for t in _content(words(para))}
        if prev_content is not None and cur and prev_content:
            overlaps.append(len(cur & prev_content) / len(cur | prev_content))
        prev_content = cur
    mean_overlap = sum(overlaps) / len(overlaps) if overlaps else 0.5
    # Inverted deliberately: low overlap between adjacent paragraphs means the
    # reader must rebuild context, which is harder. Storing 1 - overlap keeps
    # every feature oriented so that higher = more demanding.
    discontinuity = 1.0 - mean_overlap

    orphan = 0
    for i, sent in enumerate(sents):
        sent_words = words(sent)
        if not any(t in PRONOUNS for t in sent_words):
            continue
        window = " ".join(sents[max(0, i - 2):i + 1])
        if not _names(window, words(window)):
            orphan += 1
    orphan_rate = orphan / max(1, len(sents))
    shift_rate = sum(1 for t in toks if t in SHIFT_MARKERS) / max(1, len(toks) / 100.0)

    # --- I. information density -------------------------------------------
    content_ratio = len(content) / max(1, len(toks))
    seen, novel = set(), 0
    for t in content:
        if t not in seen:
            novel += 1
            seen.add(t)
    novelty = novel / max(1, len(content))
    runs, run = [], 0
    for t in toks:
        if t in STOPWORDS:
            if run:
                runs.append(run)
            run = 0
        else:
            run += 1
    if run:
        runs.append(run)
    np_len = sum(runs) / len(runs) if runs else 0.0

    # --- K. dialogue -------------------------------------------------------
    spans = quote_spans(text)
    quoted_chars = sum(e - s for s, e in spans)
    quote_density = quoted_chars / max(1, len(text))
    quoted_sentences = [s for s in sents if "\u201c" in s or '"' in s]
    tagless = 0
    for sent in quoted_sentences:
        sw = words(sent)
        if not any(t in SAID_VERBS for t in sw):
            tagless += 1
    tagless_rate = tagless / max(1, len(quoted_sentences))
    speakers = set()
    for i, t in enumerate(toks):
        if t in SAID_VERBS:
            for near in toks[max(0, i - 6):i + 7]:
                if near not in STOPWORDS and near not in PRONOUNS and near not in SAID_VERBS:
                    speakers.add(near)

    raw = {
        "A_oov": oov_rate,
        "A_morph": morph,
        "A_abstract": abstract,
        "B_sentence": mean_sentence,
        "B_clause": clause_density,
        "B_pronoun": pronoun_rate,
        "B_passive": passive_rate,
        "G_names": name_rate,
        "G_cooc": cooc,
        "H_discontinuity": discontinuity,
        "H_orphan": orphan_rate,
        "H_shift": shift_rate,
        "I_content": content_ratio,
        "I_novelty": novelty,
        "I_np": np_len,
        "K_quote": quote_density,
        "K_tagless": tagless_rate,
        "K_speakers": float(len(speakers)),
        "tokens": float(len(toks)),
        "sentences": float(len(sents)),
    }
    # Rounded once, here, so the stored artifact and the scored numbers are the
    # same values. Without this the committed feature file could not reproduce
    # the committed scores.
    return {k: round(v, 5) for k, v in raw.items()}
