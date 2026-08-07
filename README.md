# CoinSprint

A fair-launch memecoin bonding-curve launchpad for Arc:

- **`LaunchpadFactory`** — deploys gas-cheap EIP-1167 clones of the bonding curve. No admin power over tokens it has already created.
- **`MemecoinBondingCurve`** — one instance per token. 100% of supply starts on the curve (no pre-mine), no owner, no pause, no upgradeability. Graduates to a DEX pool and burns the LP once a USDC threshold is raised.
- **`TokenMetadataRegistry`** — optional image/socials per token, kept separate from the money-handling contracts on purpose.
- **`frontend/index.html`** — a single-file static UI (vanilla JS + ethers.js + Chart.js from CDN, no build step) that talks to the contracts above.

Read the NatSpec comments at the top of each `.sol` file — the design reasoning (why no admin keys, why the curve math is structured the way it is, why graduation can't brick trading) lives there, not here.

> **Not audited.** This code has an internal integration test, not a third-party security audit. Get one before putting real funds behind it on mainnet.

## Repo structure

```
arc-launchpad/
├── contracts/
│   ├── LaunchpadFactory.sol         # factory that clones the curve
│   ├── MemecoinBondingCurve.sol     # per-token bonding curve + graduation
│   ├── TokenMetadataRegistry.sol    # optional image/socials, separate contract
│   └── test/
│       └── Mocks.sol                # MockUSDC / MockFactory / MockRouter — local testing only
├── scripts/
│   ├── compile.mjs                  # solc -> compile-output.json
│   └── deploy.mjs                   # deploys the factory (+ mocks, if local)
├── test/
│   └── test-market-integration.mjs  # end-to-end check against a local node
├── frontend/
│   └── index.html                   # static UI — deploy as-is to any static host
├── hardhat.config.cjs               # only used for `npx hardhat node` (local chain)
├── package.json
├── .env.example
├── .gitignore
├── vercel.json / netlify.toml       # static frontend deploy configs
└── .github/workflows/deploy-pages.yml  # optional: auto-deploy frontend to GitHub Pages
```

Contracts, deploy tooling, and frontend are deliberately three independent layers: the frontend only needs contract addresses (pasted into its config panel or hardcoded, see below), not access to this repo's build tooling. You can deploy each piece to a different place.

## Prerequisites

- Node.js 18+
- npm
- A wallet with testnet funds if deploying to Arc Testnet

## 1. Install

```bash
git clone <your-repo-url>
cd arc-launchpad
npm install
```

## 2. Compile

```bash
npm run compile
```

This runs `scripts/compile.mjs`, which calls `solc` directly and writes `compile-output.json` at the repo root — that's the exact file `deploy.mjs` and the integration test read from (`compiled.contracts["contracts/LaunchpadFactory.sol"]["LaunchpadFactory"]`, etc.). It's a plain build artifact, gitignored, regenerate it any time.

## 3. Test locally

```bash
# terminal 1
npm run node              # starts a local JSON-RPC chain (Hardhat)

# terminal 2
npm run deploy:local      # deploys MockUSDC + MockFactory/MockRouter + the real contracts
npm run test:integration  # end-to-end check: two tokens, buys, metadata, trending sort, search
```

`deploy:local` writes `deployed-addresses.local.json` with every deployed address — that's what you paste into the frontend's config panel for local testing.

## 4. Deploy to Arc Testnet

```bash
cp .env.example .env
# fill in PRIVATE_KEY and ROUTER_ADDRESS in .env
npm run deploy:arc-testnet
```

Two things this script deliberately refuses to guess, and why:

- **`ROUTER_ADDRESS`** — no DEX has a publicly confirmed router address for Arc Testnet as of this writing. Check `docs.uniswap.org/contracts` or whichever DEX you're integrating with for the current address before setting this. Guessing wrong here means graduation silently fails forever for every token from this factory.
- **USDC address** — already hardcoded to the verified Arc Testnet USDC (`0x3600...`), sourced from Arc's own contract-address docs, not guessed.

`deploy:arc-testnet` writes `deployed-addresses.arc-testnet.json`. Consider committing that file once you're happy with a deployment — it's just public addresses, and it's a useful record of what's actually live.

## 5. Deploy the frontend

`frontend/index.html` is a single static file — no bundler, no build step. Any static host works:

**GitHub Pages** — the included workflow (`.github/workflows/deploy-pages.yml`) auto-deploys `frontend/` on every push to `main`. Just enable Pages in your repo settings (Settings → Pages → Source: GitHub Actions).

**Vercel** — `vercel.json` is already set to publish `frontend/` with no build command. `vercel --prod` or connect the repo in the Vercel dashboard.

**Netlify** — `netlify.toml` does the same. `netlify deploy --prod` or connect the repo.

**Cloudflare Pages** — connect the repo, set build output directory to `frontend`, leave the build command empty.

**Anywhere else / a plain server** — `frontend/index.html` is the entire app; copy that one file (and nothing else) to any static file host, S3 bucket, nginx root, IPFS, etc.

**Local preview:**

```bash
npm run frontend    # serves frontend/ at http://localhost:8080
```

Once it's live, open it, connect a wallet, and paste in the addresses from `deployed-addresses.<network>.json` under "Network & contract config" — factory address and USDC address are required, the metadata registry address is optional (enables images/socials).

## Security notes

- No contract in `contracts/` (excluding `contracts/test/`) has an owner, admin function, pause, or upgrade path once deployed. There is no key whose compromise affects tokens already live — see the NatSpec at the top of each file for the full reasoning.
- `contracts/test/Mocks.sol` is test-only scaffolding (mock USDC/DEX) — never deploy it anywhere real; `deploy.mjs` only deploys it when `NETWORK=local`.
- `ReentrancyGuardTransient` (EIP-1153 transient storage) requires a Cancun-enabled EVM. Confirm Arc's actual EVM version supports it before relying on it in production — `compile.mjs` and `hardhat.config.cjs` both target `evmVersion: "cancun"`.
- Get a third-party audit before deploying to mainnet with real value at stake.
