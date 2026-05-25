import os

CLOUD_PROVIDER = os.environ.get("CLOUD_PROVIDER", "env")


def get_secret(env_var: str) -> str:
    """Resolve a secret name from an env var, then fetch from the cloud provider."""
    name = os.environ.get(env_var, "")
    if not name:
        return ""

    if CLOUD_PROVIDER == "aws":
        import boto3
        client = boto3.client("secretsmanager")
        return client.get_secret_value(SecretId=name).get("SecretString", "")

    elif CLOUD_PROVIDER == "gcp":
        from google.cloud import secretmanager
        client = secretmanager.SecretManagerServiceClient()
        response = client.access_secret_version(request={"name": name})
        return response.payload.data.decode("utf-8")

    elif CLOUD_PROVIDER == "azure":
        from azure.identity import DefaultAzureCredential
        from azure.keyvault.secrets import SecretClient
        vault_url = os.environ.get("AZURE_VAULT_URL", "")
        client = SecretClient(vault_url=vault_url, credential=DefaultAzureCredential())
        return client.get_secret(name).value

    else:
        # Fallback: treat the env var value as the secret itself (local dev)
        return name
