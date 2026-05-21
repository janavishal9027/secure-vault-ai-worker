from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    gemini_api_key: str
    gemini_model: str = "gemini-2.5-flash"
    app_host: str = "0.0.0.0"
    app_port: int = 8000
    summary_chunk_threshold_chars: int = 3500
    summary_chunk_size_chars: int = 3500
    summary_max_concurrent_chunks: int = 5


settings = Settings()
