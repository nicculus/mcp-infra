FROM python:3.12-slim

# CLOUD_PROVIDER build arg selects which cloud SDK to install alongside base deps.
# Values: gcp, azure, (empty = base only for local dev)
ARG CLOUD_PROVIDER=

WORKDIR /app
COPY requirements.txt requirements-gcp.txt requirements-azure.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    $([ "$CLOUD_PROVIDER" = "gcp" ] && echo "-r requirements-gcp.txt") \
    $([ "$CLOUD_PROVIDER" = "azure" ] && echo "-r requirements-azure.txt")

COPY server.py cloud_secrets.py ./

EXPOSE 8080
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080"]
