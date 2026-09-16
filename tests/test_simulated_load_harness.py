import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))

from scripts.simulated_load_harness import (
    MARKER, PRODUCTION_VOLUME, assert_rendered_config_isolated,
    cleanup_targets, validate_isolation,
)
from scripts.run_simulated_load import Sample, percentile, summarize
from scripts import run_simulated_load_isolated as isolated


def test_requires_marker_and_names():
    with pytest.raises(ValueError): validate_isolation("", "assis-smartflow-load-x", "assis-smartflow-load-ollama-x")
    with pytest.raises(ValueError): validate_isolation(MARKER, "assis-smartflow", "assis-smartflow-load-ollama-x")
    with pytest.raises(ValueError): validate_isolation(MARKER, "assis-smartflow-load-x", PRODUCTION_VOLUME)


def test_valid_isolated_volume():
    validate_isolation(MARKER, "assis-smartflow-load-20260915", "assis-smartflow-load-ollama-20260915")
    source=(Path(__file__).parents[1]/'scripts/run_simulated_load_isolated.py').read_text(encoding='utf-8')
    assert 'assis-smartflow-e2e-ollama-cache' in source


def test_rendered_config_rejects_production_and_requires_volume():
    good = "name: assis-smartflow-load-ollama-20260915\nnetworks: isolated\n"
    assert_rendered_config_isolated(good, "assis-smartflow-load-20260915", "assis-smartflow-load-ollama-20260915")
    with pytest.raises(ValueError):
        assert_rendered_config_isolated(good.replace("isolated", PRODUCTION_VOLUME), "assis-smartflow-load-20260915", "assis-smartflow-load-ollama-20260915")
    with pytest.raises(ValueError):
        assert_rendered_config_isolated("name: assis-smartflow-load-ollama-other", "assis-smartflow-load-20260915", "assis-smartflow-load-ollama-20260915")


def test_cleanup_is_limited_to_labelled_project_resources():
    resources = [
        {"name": "load-n8n", "labels": {"com.docker.compose.project": "assis-smartflow-load-x", "assis.e2e.simulated": "true"}},
        {"name": "prod", "labels": {"com.docker.compose.project": "assis-smartflow", "assis.e2e.simulated": "true"}},
        {"name": "unlabelled", "labels": {"com.docker.compose.project": "assis-smartflow-load-x"}},
    ]
    assert cleanup_targets(resources, "assis-smartflow-load-x", "assis-smartflow-load-ollama-x") == ["load-n8n"]


def test_percentiles_and_error_classification_are_structured():
    samples = [Sample(200, 1), Sample(401, 2, 'http'), Sample(599, 3, 'TimeoutError')]
    result = summarize(samples, 1.0)
    assert result['latency_ms']['p50'] == 2
    assert result['latency_ms']['p95'] == 3
    assert result['errors'] == 2
    assert result['error_classes'] == {'http': 1, 'TimeoutError': 1}


def test_load_profiles_reuse_approved_runtime_setup_and_fail_closed():
    source = (Path(__file__).parents[1] / 'scripts' / 'run_simulated_load_profiles.py').read_text(encoding='utf-8')
    assert 'Runtime()' in source and 'rt.setup()' in source
    assert "ASSIS_E2E_SIMULATED" in source and 'required workflow missing or inactive' in source
    assert 'baseline' in source and 'metrics_unavailable' in source


def test_isolated_lifecycle_order_and_production_guards():
    source = (Path(__file__).parents[1] / 'scripts' / 'run_simulated_load_isolated.py').read_text(encoding='utf-8')
    order = ["run(['docker','volume','create'", "c(['config','--quiet'])", "c(['build','qa'])", "c(['up'", "wait_postgres_stable(compose,env,log)", "import:credentials", "import:workflow", "publish:workflow", "run','--rm','qa'"]
    positions = [source.find(item) for item in order]
    assert all(pos >= 0 for pos in positions) and positions == sorted(positions)
    assert 'ASSIS_DOMAIN' in source and 'production endpoint rejected' in source
    assert 'E2E_MODEL_VOLUME' in source and 'model cache is persistent' in source
    assert 'readiness-pollings.jsonl' in source and 'readiness-stdout.log' in source and 'readiness-stderr.log' in source
    assert "['ps','-q','n8n']" in source and "docker','inspect'" in source
    assert 'timeout=300' in source and 'HTTP 200' in source and 'status===200' in source
    assert "'exited','dead'" in source and "'unhealthy'" in source
    assert 'TimeoutExpired' in source and 'timeout=10' in source and 'returncode=124' in source
    assert 'ensure_model_cache' in source and 'assis.e2e.purpose=ollama-model-cache' in source
    assert 'Ollama daemon did not become ready' in source and "for model in ('qwen3:4b-instruct','nomic-embed-text:latest')" in source
    assert 'model-pull.stdout.log' in source and 'model-pull.stderr.log' in source and 'model-pull.exitcodes.jsonl' in source
    assert "'docker','volume','rm'" not in source


def test_isolated_qa_image_is_built_and_config_does_not_log_secrets():
    compose=(Path(__file__).parents[1]/'core/docker-compose.e2e-simulated.yml').read_text(encoding='utf-8')
    source=(Path(__file__).parents[1]/'scripts/run_simulated_load_isolated.py').read_text(encoding='utf-8')
    qa=compose.split('  qa:',1)[1].split('\nnetworks:',1)[0]
    assert 'build:' in qa and 'context: ./qa' in qa
    assert "c(['config','--quiet'])" in source and "c(['build','qa'])" in source
    assert "c(['config'])" not in source


def test_postgres_wait_rejects_init_server_and_requires_stability(monkeypatch, tmp_path):
    outcomes=iter([(2,''),(0,'1\n'),(2,''),(0,'1\n'),(0,'1\n')])
    calls=[]
    def fake_run(args, env, **kwargs):
        calls.append(args)
        code,stdout=next(outcomes)
        return isolated.SimpleNamespace(returncode=code,stdout=stdout,stderr='')
    monkeypatch.setattr(isolated,'run',fake_run)
    monkeypatch.setattr(isolated.time,'sleep',lambda _: None)

    isolated.wait_postgres_stable(['docker','compose'],{},tmp_path/'lifecycle.log',timeout=5,consecutive=2)

    assert len(calls)==5
    assert all(call[call.index('psql'):call.index('psql')+3] == ['psql','-h','127.0.0.1'] for call in calls)
    records=(tmp_path/'postgres-readiness.jsonl').read_text(encoding='utf-8').splitlines()
    assert [__import__('json').loads(row)['stable_successes'] for row in records] == [0,1,0,1,2]
    assert all('password' not in row.lower() for row in records)


def test_postgres_wait_times_out_closed(monkeypatch, tmp_path):
    ticks=iter([0.0,0.0,1.1])
    monkeypatch.setattr(isolated.time,'monotonic',lambda: next(ticks))
    monkeypatch.setattr(isolated.time,'sleep',lambda _: None)
    monkeypatch.setattr(isolated,'run',lambda *args,**kwargs: isolated.SimpleNamespace(returncode=2,stdout='',stderr=''))

    with pytest.raises(RuntimeError,match='did not become stably ready'):
        isolated.wait_postgres_stable(['docker','compose'],{},tmp_path/'lifecycle.log',timeout=1,consecutive=2)


def test_runtime_setup_uses_run_identity_namespace():
    source = (Path(__file__).parents[1] / 'tests' / 'test_waha_simulated_e2e.py').read_text(encoding='utf-8')
    assert 'self.run_id' in source and 'self.namespace' in source and 'uuid.uuid5' in source
    assert "self.success_key='complete-'+self.run_id" in source
    assert "result.get('duplicate') is True" in source
    setup=source.split('    def setup(self):',1)[1].split('    def cleanup(self):',1)[0]
    assert 'uuid.uuid4()' not in setup


def test_single_loaded_model_flag_is_not_present_in_load_override():
    override=(Path(__file__).parents[1]/'core/docker-compose.load-simulated.override.yml').read_text(encoding='utf-8')
    production=(Path(__file__).parents[1]/'core/docker-compose.yml').read_text(encoding='utf-8')
    harness=(Path(__file__).parents[1]/'scripts/run_simulated_load_isolated.py').read_text(encoding='utf-8')
    obsolete='OLLAMA_MAX_'+'LOADED_MODELS'
    assert obsolete not in override
    assert obsolete not in production
    assert obsolete not in harness
    assert 'embed-proxy:11434/api/embed' in harness


def test_embed_proxy_changes_only_embedding_endpoint():
    proxy=(Path(__file__).parents[1]/'scripts/ollama_embed_proxy.js').read_text(encoding='utf-8')
    harness=(Path(__file__).parents[1]/'scripts/run_simulated_load_isolated.py').read_text(encoding='utf-8')
    assert "j.keep_alive=0" in proxy and 'api/chat' not in proxy
    override=(Path(__file__).parents[1]/'core/docker-compose.load-simulated.override.yml').read_text(encoding='utf-8')
    assert 'entrypoint: ["node"]' in override and 'command: ["/proxy/ollama_embed_proxy.js"]' in override
    assert "endswith('/api/embed')" in harness and 'embed-proxy:11434/api/embed' in harness
