FROM python:3.13.15-slim AS builder

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

FROM python:3.13.15-slim

RUN rm -rf \
      /usr/local/lib/python*/ensurepip \
      /usr/local/lib/python*/site-packages/pip* \
      /usr/local/lib/python*/site-packages/setuptools* \
      /usr/local/lib/python*/site-packages/wheel* \
      /usr/local/lib/python*/site-packages/jaraco* \
      /usr/local/lib/python*/site-packages/_distutils_hack \
 && groupadd --system --gid 10001 assis \
 && useradd --system --uid 10001 --gid assis \
      --home-dir /app --no-create-home assis

RUN rm -f /usr/local/bin/pip*

ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=assis:assis app.py /app/app.py

USER 10001:10001

EXPOSE 8080

CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8080"]
