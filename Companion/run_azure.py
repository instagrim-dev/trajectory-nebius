"""Start the loopback companion with the existing host Azure OpenAI setup."""
import json
import os
from pathlib import Path
import sys

config = Path(os.environ.get(
    "TRAJECTORY_AZURE_CONFIG_DIR", str(Path.home() / ".config/bmo-azure-codex")))
settings = json.loads((config / "state.json").read_text())
credential = (config / "azure_openai_api_key").read_text().strip()
if not credential or not settings["endpoint"].startswith("https://"):
    raise SystemExit("Existing Azure OpenAI configuration is incomplete")
os.environ.pop("META_API_KEY", None)
os.environ.update(
    TRAJECTORY_GENERATOR_PROVIDER="azure_openai",
    TRAJECTORY_GENERATOR_MODEL=settings["models"]["execution"],
    AZURE_OPENAI_BASE_URL=settings["endpoint"],
    AZURE_OPENAI_API_KEY=credential,
)
os.execv(sys.executable, [sys.executable, "-u",
                        str(Path(__file__).with_name("server.py")), *sys.argv[1:]])
