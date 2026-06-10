from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Summaries run on Gemini via its OpenAI-compatible endpoint, called with
    # the standard AsyncOpenAI client. These GEMINI_* env vars drive that client.
    gemini_api_key: str = ""
    gemini_base_url: str = "https://generativelanguage.googleapis.com/v1beta/openai/"
    gemini_model: str = "gemini-2.0-flash"

    app_host: str = "0.0.0.0"
    app_port: int = 8000
    summary_chunk_threshold_chars: int = 3500
    summary_chunk_size_chars: int = 3500
    summary_max_concurrent_chunks: int = 5


settings = Settings()
