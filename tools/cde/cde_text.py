"""Text primitives for the Cognitive Difficulty Engine.

Pure functions, standard library only. These are deliberately separate from
feature extraction so that segmentation accuracy can be tested on its own.

The sentence splitter here is the *canonical* one: a terminator ends a sentence
only when the next non-space character starts a new sentence (capital letter or
end of text), with an abbreviation guard. This is the fix for defect X5 in
docs/plans/cde/PHASE-1-AUDIT.md, where the shipped analyzer split on every
period and over-counted sentences by 1.34x.
"""

from __future__ import annotations

import re

WORD_RE = re.compile(r"[A-Za-z][A-Za-z'’\-]*")
SENTENCE_END = (".", "!", "?")

ABBREVIATIONS = {
    "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "capt", "col", "gen",
    "lt", "sgt", "rev", "hon", "vs", "etc", "e.g", "i.e", "no", "vol", "ch",
    "p", "pp", "fig", "mt", "ft",
}

STOPWORDS = set("""
a about above after again against all am an and any are aren't as at be because
been before being below between both but by can't cannot could couldn't did
didn't do does doesn't doing don't down during each few for from further had
hadn't has hasn't have haven't having he he'd he'll he's her here here's hers
herself him himself his how how's i i'd i'll i'm i've if in into is isn't it
it's its itself let's me more most mustn't my myself no nor not of off on once
only or other ought our ours ourselves out over own same shan't she she'd
she'll she's should shouldn't so some such than that that's the their theirs
them themselves then there there's these they they'd they'll they're they've
this those through to too under until up very was wasn't we we'd we'll we're
we've were weren't what what's when when's where where's which while who who's
whom why why's with won't would wouldn't you you'd you'll you're you've your
yours yourself yourselves
""".split())

NEGATIONS = {"not", "no", "never", "none", "nothing", "nobody", "nowhere",
             "neither", "nor", "cannot", "can't", "don't", "didn't", "doesn't",
             "isn't", "wasn't", "weren't", "won't", "wouldn't", "couldn't"}

SUBORDINATORS = {
    "because", "although", "though", "while", "whilst", "if", "unless", "when",
    "whenever", "where", "wherever", "whether", "that", "which", "who", "whom",
    "whose", "after", "before", "since", "until", "as", "once", "whereas",
}

COORDINATORS = {"and", "but", "or", "yet", "so", "for", "nor"}

PRONOUNS = {"i", "you", "he", "she", "it", "we", "they", "him", "her", "them",
            "us", "me", "his", "hers", "its", "their", "our", "my", "your",
            "himself", "herself", "itself", "themselves", "ourselves", "myself",
            "yourself", "theirs", "ours", "yours", "one"}

BE_FORMS = {"is", "are", "was", "were", "be", "been", "being", "am"}

SAID_VERBS = {"said", "asked", "replied", "answered", "muttered", "whispered",
              "shouted", "called", "cried", "added", "continued", "began",
              "told", "explained", "demanded", "suggested", "murmured",
              "repeated", "insisted", "agreed", "snapped", "growled"}

# Deliberately excludes "now", "then" and "across": they are too common in
# ordinary narrative to signal a scene shift, and including them made the
# dimension measure adverb frequency rather than discontinuity.
SHIFT_MARKERS = {"meanwhile", "later", "earlier", "elsewhere", "afterwards",
                 "afterward", "eventually", "simultaneously", "somewhere"}

ABSTRACT_SUFFIXES = ("tion", "sion", "ment", "ness", "ity", "ism", "ance",
                     "ence", "ship", "hood", "acy", "ology", "ography")

MORPH_SUFFIXES = ("tion", "sion", "ment", "ness", "ity", "ism", "ous", "ive",
                  "ate", "ify", "ize", "ise", "ance", "ence", "able", "ible",
                  "ally", "ical", "ary", "ory")


def words(text):
    """Lowercased word tokens, apostrophes preserved."""
    return [m.group(0).lower() for m in WORD_RE.finditer(text)]


def raw_words(text):
    """Surface word tokens, original case."""
    return [m.group(0) for m in WORD_RE.finditer(text)]


def split_paragraphs(text):
    return [p.strip() for p in text.split("\n") if p.strip()]


def split_sentences(text):
    """Canonical splitter: terminator only counts before a capital or the end."""
    sentences = []
    start = 0
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch not in SENTENCE_END:
            i += 1
            continue

        # Abbreviation guard: look back at the word before the terminator.
        j = i - 1
        while j >= 0 and text[j] not in " \t\n":
            j -= 1
        prev = text[j + 1:i].lower().strip(".,!?\"'“”‘’()[]")
        if prev in ABBREVIATIONS:
            i += 1
            continue
        if prev.isdigit():
            i += 1
            continue

        # Look ahead to the next non-space character.
        k = i + 1
        while k < n and text[k] in " \t\n\r\"":
            k += 1
        at_end = k >= n
        next_ch = text[k] if not at_end else ""
        if at_end or next_ch.isupper() or next_ch in "\"'“‘(":
            sentence = text[start:k].strip()
            if sentence:
                sentences.append(sentence)
            start = k
            i = k
            continue
        i += 1

    tail = text[start:].strip()
    if tail:
        sentences.append(tail)
    return sentences


def is_prose(text):
    """Cheap prose test: rejects tables of contents, indexes and page scans."""
    tokens = words(text)
    if len(tokens) < 40:
        return False
    digits = sum(1 for t in text.split() if any(c.isdigit() for c in t))
    if digits / max(1, len(text.split())) > 0.20:
        return False
    sentences = split_sentences(text)
    if not sentences:
        return False
    mean_sentence = len(tokens) / len(sentences)
    if mean_sentence < 4.0:
        return False
    return True


def syllables(word):
    """Vowel-group estimate, matching the app's shipped heuristic."""
    letters = [c for c in word if c.isalpha()]
    if not letters:
        return 1
    count = 0
    prev_vowel = False
    for c in letters:
        vowel = c in "aeiouy"
        if vowel and not prev_vowel:
            count += 1
        prev_vowel = vowel
    if len(letters) > 1 and letters[-1] == "e" and count > 1:
        count -= 1
    return max(1, count)


def quote_spans(text):
    """Return (start, end) spans of quoted speech for single and double quotes."""
    spans = []
    for open_ch, close_ch in (("\u201c", "\u201d"), ('"', '"')):
        start = None
        for i, ch in enumerate(text):
            if ch == open_ch and start is None:
                start = i
            elif ch == close_ch and start is not None:
                spans.append((start, i))
                start = None
    spans.sort()
    return spans


def capitalised_runs(text):
    """Capitalised tokens with token index, for name extraction."""
    out = []
    for idx, m in enumerate(WORD_RE.finditer(text)):
        token = m.group(0)
        if token[0].isupper() and not token.isupper():
            out.append((idx, token))
    return out
