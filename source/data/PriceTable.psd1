@{
    # Usage-based pricing. USD per 1M tokens. Verified 2026-08-06 against
    # https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing
    # Edit this file to add or update model rates - no module code changes needed.
    #
    # Schema
    #   Input / CachedInput / CacheWrite / Output   the Default tier rates.
    #   CacheWrite = $null                          model has no separate cache-write rate.
    #   LongContext = @{ Threshold = <input tokens>; ... }
    #                                               optional second tier, billed when a
    #                                               single request's input tokens EXCEED
    #                                               Threshold. Omit for flat-rate models.
    #
    # Billing note: 1 GitHub AI credit = 0.01 USD.

    # --- OpenAI --------------------------------------------------------------
    'gpt-4.1'       = @{ Input = 2.00; CachedInput = 0.50;  CacheWrite = $null; Output = 8.00  }
    'gpt-5.2'       = @{ Input = 1.75; CachedInput = 0.175; CacheWrite = $null; Output = 14.00 }
    'gpt-5.2-codex' = @{ Input = 1.75; CachedInput = 0.175; CacheWrite = $null; Output = 14.00 }
    'gpt-5.3-codex' = @{ Input = 1.75; CachedInput = 0.175; CacheWrite = $null; Output = 14.00 }
    'gpt-5-mini'    = @{ Input = 0.25; CachedInput = 0.025; CacheWrite = $null; Output = 2.00  }
    'gpt-5.4-mini'  = @{ Input = 0.75; CachedInput = 0.075; CacheWrite = $null; Output = 4.50  }
    'gpt-5.4-nano'  = @{ Input = 0.20; CachedInput = 0.02;  CacheWrite = $null; Output = 1.25  }

    'gpt-5.4' = @{
        Input = 2.50; CachedInput = 0.25; CacheWrite = $null; Output = 15.00
        LongContext = @{ Threshold = 272000; Input = 5.00; CachedInput = 0.50; CacheWrite = $null; Output = 22.50 }
    }
    'gpt-5.5' = @{
        Input = 5.00; CachedInput = 0.50; CacheWrite = $null; Output = 30.00
        LongContext = @{ Threshold = 272000; Input = 10.00; CachedInput = 1.00; CacheWrite = $null; Output = 45.00 }
    }
    # The GPT-5.6 family is the only OpenAI line that bills a separate cache
    # write; earlier OpenAI models have none.
    'gpt-5.6-luna' = @{
        Input = 0.20; CachedInput = 0.02; CacheWrite = 0.25; Output = 1.20
        LongContext = @{ Threshold = 200000; Input = 0.40; CachedInput = 0.04; CacheWrite = 0.50; Output = 1.80 }
    }
    'gpt-5.6-sol' = @{
        Input = 5.00; CachedInput = 0.50; CacheWrite = 6.25; Output = 30.00
        LongContext = @{ Threshold = 272000; Input = 10.00; CachedInput = 1.00; CacheWrite = 12.50; Output = 45.00 }
    }
    'gpt-5.6-terra' = @{
        Input = 2.00; CachedInput = 0.20; CacheWrite = 2.50; Output = 12.00
        LongContext = @{ Threshold = 272000; Input = 4.00; CachedInput = 0.40; CacheWrite = 5.00; Output = 18.00 }
    }

    # --- Anthropic (these models bill a separate cache-write rate) ------------
    'claude-haiku-4.5'  = @{ Input = 1.00; CachedInput = 0.10; CacheWrite = 1.25; Output = 5.00  }
    'claude-sonnet-4'   = @{ Input = 3.00; CachedInput = 0.30; CacheWrite = 3.75; Output = 15.00 }
    'claude-sonnet-4.5' = @{ Input = 3.00; CachedInput = 0.30; CacheWrite = 3.75; Output = 15.00 }
    'claude-sonnet-4.6' = @{ Input = 3.00; CachedInput = 0.30; CacheWrite = 3.75; Output = 15.00 }
    'claude-opus-4.5'   = @{ Input = 5.00; CachedInput = 0.50; CacheWrite = 6.25; Output = 25.00 }
    'claude-opus-4.6'   = @{ Input = 5.00; CachedInput = 0.50; CacheWrite = 6.25; Output = 25.00 }
    'claude-opus-4.7'   = @{ Input = 5.00; CachedInput = 0.50; CacheWrite = 6.25; Output = 25.00 }
    'claude-opus-4.8'   = @{ Input = 5.00; CachedInput = 0.50; CacheWrite = 6.25; Output = 25.00 }
    'claude-opus-5'     = @{ Input = 5.00; CachedInput = 0.50; CacheWrite = 6.25; Output = 25.00 }
    # Sonnet 5 introductory pricing ends 2026-08-31; standard rates from
    # 2026-09-01 are Input 3.00 / CachedInput 0.30 / CacheWrite 3.75 / Output 15.00.
    'claude-sonnet-5'   = @{ Input = 2.00; CachedInput = 0.20; CacheWrite = 2.50; Output = 10.00 }
    # Rates are published but the service does not advertise these ids yet, so
    # the keys are the documented model names slugged to this table's convention.
    'claude-opus-4.8-fast' = @{ Input = 10.00; CachedInput = 1.00; CacheWrite = 12.50; Output = 50.00 }
    'claude-fable-5'       = @{ Input = 10.00; CachedInput = 1.00; CacheWrite = 12.50; Output = 50.00 }

    # --- Google ---------------------------------------------------------------
    'gemini-2.5-pro'   = @{ Input = 1.25; CachedInput = 0.125; CacheWrite = $null; Output = 10.00 }
    'gemini-3-flash'   = @{ Input = 0.50; CachedInput = 0.05;  CacheWrite = $null; Output = 3.00  }
    'gemini-3.5-flash' = @{ Input = 1.50; CachedInput = 0.15;  CacheWrite = $null; Output = 9.00  }
    'gemini-3.6-flash' = @{ Input = 1.50; CachedInput = 0.15;  CacheWrite = $null; Output = 7.50  }
    # The service advertises the -preview ids; keep both spellings so either resolves.
    'gemini-3-flash-preview' = @{ Input = 0.50; CachedInput = 0.05; CacheWrite = $null; Output = 3.00 }
    'gemini-3.1-pro' = @{
        Input = 2.00; CachedInput = 0.20; CacheWrite = $null; Output = 12.00
        LongContext = @{ Threshold = 200000; Input = 4.00; CachedInput = 0.40; CacheWrite = $null; Output = 18.00 }
    }
    'gemini-3.1-pro-preview' = @{
        Input = 2.00; CachedInput = 0.20; CacheWrite = $null; Output = 12.00
        LongContext = @{ Threshold = 200000; Input = 4.00; CachedInput = 0.40; CacheWrite = $null; Output = 18.00 }
    }

    # --- Microsoft ------------------------------------------------------------
    'mai-code-1-flash'        = @{ Input = 0.75; CachedInput = 0.075; CacheWrite = $null; Output = 4.50 }
    'mai-code-1-flash-picker' = @{ Input = 0.75; CachedInput = 0.075; CacheWrite = $null; Output = 4.50 }

    # --- xAI ------------------------------------------------------------------
    # Cached input is 0.25x input here, not the 0.1x the other vendors use.
    'grok-4.5' = @{
        Input = 2.00; CachedInput = 0.50; CacheWrite = $null; Output = 6.00
        LongContext = @{ Threshold = 200000; Input = 4.00; CachedInput = 1.00; CacheWrite = $null; Output = 12.00 }
    }

    # --- Moonshot AI ----------------------------------------------------------
    # Published rates; id slugged to this table's convention (not yet advertised).
    'kimi-k2.7-code' = @{ Input = 0.95; CachedInput = 0.19; CacheWrite = $null; Output = 4.00 }

    # --- Fine-tuned (GitHub) --------------------------------------------------
    'raptor-mini' = @{ Input = 0.25; CachedInput = 0.025; CacheWrite = $null; Output = 2.00  }
    'goldeneye'   = @{ Input = 1.25; CachedInput = 0.125; CacheWrite = $null; Output = 10.00 }
}
