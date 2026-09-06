#!/usr/bin/env python3
"""Validate forge evidence consumed by fm-pr-landed-lib.sh.

Usage: fm-pr-evidence.py pr|base|repository|comparison < gh-axi response
       fm-pr-evidence.py gitlab-pr|gitlab-base|gitlab-repository|gitlab-ancestor < JSON
The gh-axi 0.1.29 API has no raw JSON output mode: even --jq/--template
results are rendered as TOON. This deliberately bounded fallback accepts only
these flat records, decoding quoted strings with JSON's compatible scalar
escapes and validating both quoted and bare values against the field schema.
It is not a general TOON decoder. Missing/null required evidence exits 2
(retryable); optional fields may be absent/null. Every present schema field
is validated before returning retryable absence, so missing evidence cannot
mask malformed evidence, which exits 4 with its field name (never retryable).
tests/fm-pr-merge.test.sh covers this precedence and both scalar styles.
Successful output is one value per line in the order consumed by the caller.
"""
import json
import re
import subprocess
import sys


class EvidenceError(Exception):
    def __init__(self, message, code=4):
        super().__init__(message)
        self.code = code


def read_record(text):
    record = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        key, sep, raw = line.partition(':')
        if not sep or not re.fullmatch(r'[a-z_]+', key):
            raise EvidenceError('invalid forge evidence record')
        if key in record:
            raise EvidenceError(f'invalid forge evidence field {key}: duplicate')
        raw = raw.strip()
        if not raw:
            raise EvidenceError(f'invalid forge evidence field {key}: empty scalar')
        if raw.startswith('"'):
            try:
                value = json.loads(raw)
            except ValueError as exc:
                raise EvidenceError(f'invalid forge evidence field {key}: malformed quoted scalar') from exc
        elif raw == 'null':
            value = None
        elif raw in ('true', 'false'):
            value = raw == 'true'
        elif re.fullmatch(r'[^\s"\[\]{},:]+', raw):
            value = raw
        else:
            raise EvidenceError(f'invalid forge evidence field {key}: malformed bare scalar')
        record[key] = value
    return record


def field(record, key, pattern=None, optional=False):
    if key not in record or record[key] is None:
        if optional:
            return ''
        raise EvidenceError(f'forge evidence field {key} is absent or null', 2)
    value = record[key]
    if pattern is None:
        if type(value) is not bool:
            raise EvidenceError(f'invalid forge evidence field {key}: expected boolean')
        return 'true' if value else 'false'
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise EvidenceError(f'invalid forge evidence field {key}: unexpected value')
    if key in ('base_ref', 'default_branch'):
        try:
            result = subprocess.run(
                ['git', 'check-ref-format', '--branch', value],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError as exc:
            raise EvidenceError(f'forge evidence field {key}: branch validation unavailable') from exc
        if result.returncode != 0:
            raise EvidenceError(f'invalid forge evidence field {key}: invalid branch')
    return value


def main():
    mode = sys.argv[1]
    text = sys.stdin.read()
    if mode.startswith('gitlab-'):
        try:
            raw = json.loads(text)
            if not isinstance(raw, dict):
                raise ValueError('expected object')
        except ValueError as exc:
            raise EvidenceError('invalid forge evidence JSON') from exc
        mode = mode.removeprefix('gitlab-')
        record = raw
        if mode in ('pr', 'base'):
            record = dict(raw, base_ref=raw.get('target_branch'))
        if mode == 'pr':
            if raw.get('state') not in ('opened', 'closed', 'locked', 'merged'):
                raise EvidenceError('invalid forge evidence field state')
            record.update(merged=raw['state'] == 'merged',
                          merge_commit=raw.get('merge_commit_sha') or raw.get('squash_commit_sha'))
            # GitLab timestamps may carry millisecond precision.
            if isinstance(record.get('merged_at'), str):
                record['merged_at'] = re.sub(r'\.\d+Z$', 'Z', record['merged_at'])
    else:
        record = read_record(text)
    branch = r'[^\s\x00-\x1f\x7f]+'
    if mode == 'pr':
        unmerged = record.get('merged') is False
        schema = [
            ('merged', None, False),
            ('merge_commit', r'[0-9a-f]{40}', unmerged),
            ('base_ref', branch, unmerged),
            ('merged_at', r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', True),
        ]
        values = []
        missing = None
        for key, pattern, optional in schema:
            try:
                values.append(field(record, key, pattern, optional))
            except EvidenceError as error:
                if error.code != 2:
                    raise
                if missing is None:
                    missing = error
        if missing is not None:
            raise missing
        if unmerged:
            values = values[:1]
    elif mode == 'base':
        values = [field(record, 'base_ref', branch)]
    elif mode == 'ancestor':
        values = [field(record, 'id', r'[0-9a-f]{40}')]
    elif mode == 'repository':
        values = [field(record, 'default_branch', branch)]
    elif mode == 'comparison':
        values = [field(record, 'status', r'ahead|identical|behind|diverged')]
    else:
        raise EvidenceError('invalid forge evidence reader mode')
    print('\n'.join(values))


if __name__ == '__main__':
    try:
        main()
    except EvidenceError as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(error.code)
