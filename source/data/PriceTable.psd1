@{
    # Usage-based pricing (effective 2026-06-01). USD per 1M tokens.
    # Edit this file to add or update model rates - no module code changes needed.
    # CacheWrite = $null means the model has no separate cache-write rate.
    'gpt-4.1'           = @{ Input = 2.00; CachedInput = 0.50;  CacheWrite = $null; Output = 8.00  }
    'gpt-5.2-codex'     = @{ Input = 1.75; CachedInput = 0.175; CacheWrite = $null; Output = 14.00 }
    'gpt-5.3-codex'     = @{ Input = 1.75; CachedInput = 0.175; CacheWrite = $null; Output = 14.00 }
    'gpt-5.5'           = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = $null; Output = 30.00 }
    'gpt-5.2'           = @{ Input = 1.75; CachedInput = 0.175; CacheWrite = $null; Output = 14.00 }
    'gpt-5.4'           = @{ Input = 2.50; CachedInput = 0.25;  CacheWrite = $null; Output = 15.00 }
    'gpt-5.6-luna'      = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = $null; Output = 30.00 }
    'gpt-5.6-sol'       = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = $null; Output = 30.00 }
    'gpt-5.6-terra'     = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = $null; Output = 30.00 }
    'gpt-5-mini'        = @{ Input = 0.25; CachedInput = 0.025; CacheWrite = $null; Output = 2.00  }
    'gpt-5.4-mini'      = @{ Input = 0.75; CachedInput = 0.075; CacheWrite = $null; Output = 4.50  }
    'gpt-5.4-nano'      = @{ Input = 0.20; CachedInput = 0.02;  CacheWrite = $null; Output = 1.25  }
    'claude-opus-4.5'   = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = 6.25;  Output = 25.00 }
    'claude-opus-4.6'   = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = 6.25;  Output = 25.00 }
    'claude-opus-4.7'   = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = 6.25;  Output = 25.00 }
    'claude-opus-4.8'   = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = 6.25;  Output = 25.00 }
    'claude-opus-5'     = @{ Input = 5.00; CachedInput = 0.50;  CacheWrite = 6.25;  Output = 25.00 }
    'claude-sonnet-4'   = @{ Input = 3.00; CachedInput = 0.30;  CacheWrite = 3.75;  Output = 15.00 }
    'claude-sonnet-4.5' = @{ Input = 3.00; CachedInput = 0.30;  CacheWrite = 3.75;  Output = 15.00 }
    'claude-sonnet-4.6' = @{ Input = 3.00; CachedInput = 0.30;  CacheWrite = 3.75;  Output = 15.00 }
    # Sonnet 5 introductory pricing ends 2026-08-31; standard rates from
    # 2026-09-01 are Input 3.00 / CachedInput 0.30 / CacheWrite 3.75 / Output 15.00.
    'claude-sonnet-5'   = @{ Input = 2.00; CachedInput = 0.20;  CacheWrite = 2.50;  Output = 10.00 }
    'claude-haiku-4.5'  = @{ Input = 1.00; CachedInput = 0.10;  CacheWrite = 1.25;  Output = 5.00  }
    'gemini-2.5-pro'    = @{ Input = 1.25; CachedInput = 0.125; CacheWrite = $null; Output = 10.00 }
    'gemini-3.1-pro'    = @{ Input = 2.00; CachedInput = 0.20;  CacheWrite = $null; Output = 12.00 }
    'gemini-3-flash'    = @{ Input = 0.50; CachedInput = 0.05;  CacheWrite = $null; Output = 3.00  }
    'gemini-3.5-flash'  = @{ Input = 1.50; CachedInput = 0.15;  CacheWrite = $null; Output = 9.00  }
    'raptor-mini'       = @{ Input = 0.25; CachedInput = 0.025; CacheWrite = $null; Output = 2.00  }
    'goldeneye'         = @{ Input = 1.25; CachedInput = 0.125; CacheWrite = $null; Output = 10.00 }
}