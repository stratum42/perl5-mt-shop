FROM --platform=linux/amd64 python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libxml2 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir ibm_db

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 50050
CMD ["python3", "-u", "/app/server.py"]
