from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    openai_api_key: str = ""
    openai_base_url: str = "https://openrouter.ai/api/v1"
    openai_model: str = "openai/gpt-oss-120b"
    openai_app_title: str = "secure-vault"

    app_host: str = "0.0.0.0"
    app_port: int = 8000
    summary_chunk_threshold_chars: int = 3500
    summary_chunk_size_chars: int = 3500
    summary_max_concurrent_chunks: int = 5


settings = Settings()
