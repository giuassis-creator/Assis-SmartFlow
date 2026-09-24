FROM python:3.11.16-slim AS builder

RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade \
      pip setuptools==80.9.0 wheel==0.46.2

COPY requirements.txt /tmp/requirements.txt

RUN /opt/venv/bin/pip install --no-cache-dir \
      -r /tmp/requirements.txt \
 && /opt/venv/bin/pip check \
 && rm -rf \
      /opt/venv/lib/python*/site-packages/pip* \
      /opt/venv/lib/python*/site-packages/setuptools* \
      /opt/venv/lib/python*/site-packages/wheel* \
      /opt/venv/lib/python*/site-packages/jaraco* \
      /opt/venv/bin/pip*

FROM python:3.11.16-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg curl \
 && rm -rf \
      /var/lib/apt/lists/* \
      /usr/local/lib/python*/ensurepip \
      /usr/local/lib/python*/site-packages/pip* \
      /usr/local/lib/python*/site-packages/setuptools* \
      /usr/local/lib/python*/site-packages/wheel* \
      /usr/local/lib/python*/site-packages/jaraco* \
      /usr/local/lib/python*/site-packages/_distutils_hack

RUN rm -f /usr/local/bin/pip*

RUN groupadd --system --gid 10001 assis \
 && useradd --system --uid 10001 --gid assis \
      --create-home --home-dir /home/assis assis \
 && install -d -o assis -g assis \
      /home/assis/.cache/huggingface

ENV PATH="/opt/venv/bin:$PATH"
ENV HOME="/home/assis"
ENV HF_HOME="/home/assis/.cache/huggingface"

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY app.py /app/app.py

USER 10001:10001

HEALTHCHECK --interval=20s --timeout=5s --retries=10 \
  CMD curl -fsS http://localhost:8000/health || exit 1

CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8000"]
