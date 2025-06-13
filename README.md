# Simulation of Pairs Trading Strategy

- **Project:** Pairs Trading Strategy Implementation using Cointegration Techniques
- **Author:** Abdurrahman Fadhil
- **Date:** 13 June 2025
- **Description:** This script implements a statistical arbitrage pairs trading strategy based on
cointegration analysis of four major Indonesian bank stocks:
  - BBRI (Bank Rakyat Indonesia)
  - BBNI (Bank Negara Indonesia) 
  - BBCA (Bank Central Asia)
  - BMRI (Bank Mandiri)
- The simulation follows these steps:
  1. Data preprocessing and cointegration testing
  2. Rolling regression to estimate time-varying hedge ratios
  3. Spread calculation and threshold-based trading signals
  4. Performance comparison with buy-and-hold strategies
- Package requirements:
  - `ssc install egranger`
