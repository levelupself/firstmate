#!/usr/bin/env python3
"""Read the flat scalar records requested by fm-pr-merge.sh from gh-axi.

Usage: fm-pr-evidence.py pr|repository|comparison < response
The installed gh-axi API has no raw JSON output mode: even --jq/--template
results are rendered as TOON. This deliberately bounded fallback accepts only
these flat records, decoding quoted strings with JSON's compatible scalar
escapes and validating both quoted and bare values against the field schema.
It is not a general TOON decoder. Missing/null evidence exits 2 (retryable);
present malformed evidence exits 4 with its field name (never retryable).
Successful output is one value per line in the order consumed by the caller.
"""
import json
import re
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
    return value


def main():
    record = read_record(sys.stdin.read())
    branch = r'[^\s\x00-\x1f\x7f]+'
    if sys.argv[1] == 'pr':
        merged = field(record, 'merged')
        if merged == 'false':
            print(merged)
            return
        values = [
            merged,
            field(record, 'merge_commit', r'[0-9a-f]{40}'),
            field(record, 'base_ref', branch),
            field(record, 'merged_at', r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', optional=True),
        ]
    elif sys.argv[1] == 'repository':
        values = [field(record, 'default_branch', branch)]
    elif sys.argv[1] == 'comparison':
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
