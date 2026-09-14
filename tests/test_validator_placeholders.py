import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def validate_template(tmp_path, text, filename='.env.example'):
    scripts = tmp_path / 'scripts'
    scripts.mkdir()
    validator = scripts / 'validate.py'
    validator.write_bytes((ROOT / 'scripts/validate.py').read_bytes())
    target = tmp_path / filename
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding='utf-8')
    return subprocess.run(
        [sys.executable, str(validator)], capture_output=True, text=True
    )


@pytest.mark.parametrize('value', ['CHANGE_ME', 'CHANGE_ME_LONG_RANDOM_WAHA_API_KEY'])
def test_exact_placeholder_is_accepted(tmp_path, value):
    result = validate_template(tmp_path, 'WAHA_API_KEY=' + value + '\n')
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize('key', [
    'INTERNAL_AGENT_TOKEN', 'POSTGRES_PASSWORD', 'REDIS_PASSWORD',
    'N8N_ENCRYPTION_KEY', 'WAHA_API_KEY', 'WAHA_WEBHOOK_SECRET',
    'WAHA_DASHBOARD_PASSWORD', 'EVOLUTION_WEBHOOK_SECRET',
    'CHATWOOT_WEBHOOK_SECRET', 'DB_POSTGRESDB_PASSWORD',
    'EVOLUTION_API_KEY', 'S3_ACCESS_KEY', 'S3_SECRET_KEY',
])
def test_real_looking_credential_assignments_are_blocked(tmp_path, key):
    value = 'aB7_' + '9xR2' * 8
    result = validate_template(tmp_path, key + '=' + value + '\n')
    assert result.returncode != 0
    assert 'possible committed secret' in result.stdout
    assert value not in result.stdout + result.stderr


@pytest.mark.parametrize('value', [
    'prefix_CHANGE_ME', 'CHANGE_ME_suffix', 'CHANGE_ME_LONG_RANDOM_WAHA_API_KEY_extra',
    'CHANGE_ME_LONG_RANDOM_WAHA_API_KEY.extra',
    'CHANGE_ME_LONG_RANDOM_WAHA_API_KEY trailing',
    'CHANGE_ME_LONG_RANDOM_INTERNAL_TOKEN', 'change_me', '"CHANGE_ME"',
])
def test_placeholder_substrings_and_wrong_context_are_blocked(tmp_path, value):
    result = validate_template(tmp_path, 'WAHA_API_KEY=' + value + '\n')
    assert result.returncode != 0
    assert 'possible committed secret' in result.stdout


@pytest.mark.parametrize('filename', ['other.example', 'nested/.env.example', 'config.yml'])
def test_placeholder_exception_is_not_a_file_or_extension_exclusion(tmp_path, filename):
    result = validate_template(
        tmp_path, 'WAHA_API_KEY=' + 'CHANGE_ME_LONG_RANDOM_WAHA_API_KEY\n', filename
    )
    assert result.returncode != 0


@pytest.mark.parametrize('value', [
    'ghp_' + 'a' * 24, 'sk-' + 'b' * 24, 'AKIA' + 'C' * 16,
    'api_key=' + 'd' * 24,
])
def test_recognized_placeholder_does_not_hide_other_secrets(tmp_path, value):
    text = 'WAHA_API_KEY=' + 'CHANGE_ME_LONG_RANDOM_WAHA_API_KEY\n# ' + value + '\n'
    result = validate_template(tmp_path, text)
    assert result.returncode != 0
    assert 'possible committed secret' in result.stdout
    assert value not in result.stdout + result.stderr
