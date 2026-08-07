// Compiles every contract with solc directly (not through a framework's
// own artifact pipeline) and writes a single standard-JSON-shaped
// compile-output.json at the repo root.
//
// This exact shape — output.contracts[sourceFile][contractName] — is what
// scripts/deploy.mjs and test/test-market-integration.mjs already expect
// (see their `artifact(file, name)` helper). Keeping compilation as its
// own explicit step, instead of hiding it inside a framework, means both
// of those scripts stay framework-agnostic and easy to read end to end.
//
// Run: npm run compile

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import solc from "solc";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

// Every local contract is listed explicitly and provided directly in
// `sources` below, so solc never has to resolve a relative "./X.sol"
// import on its own — only the @openzeppelin/* imports need resolving
// off disk via the `findImport` callback.
const SOURCE_FILES = [
  "contracts/LaunchpadFactory.sol",
  "contracts/MemecoinBondingCurve.sol",
  "contracts/TokenMetadataRegistry.sol",
  "contracts/test/Mocks.sol",
];

const sources = {};
for (const relPath of SOURCE_FILES) {
  sources[relPath] = { content: fs.readFileSync(path.join(ROOT, relPath), "utf8") };
}

function findImport(importPath) {
  if (importPath.startsWith("@openzeppelin/")) {
    try {
      return { contents: fs.readFileSync(path.join(ROOT, "node_modules", importPath), "utf8") };
    } catch {
      return { error: `Could not resolve ${importPath} — did you run "npm install"?` };
    }
  }
  return { error: `File not found: ${importPath}` };
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    // MemecoinBondingCurve uses ReentrancyGuardTransient (EIP-1153
    // transient storage), which requires Cancun. Confirm Arc's live EVM
    // version actually supports Cancun before deploying there for real —
    // see README.md.
    evmVersion: "cancun",
    outputSelection: {
      "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] },
    },
  },
};

console.log(`Compiling with solc ${solc.version()}...`);
const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImport }));

let hasError = false;
for (const err of output.errors || []) {
  if (err.severity === "error") {
    hasError = true;
    console.error(err.formattedMessage);
  } else {
    console.warn(err.formattedMessage);
  }
}
if (hasError) {
  console.error("\nCompilation failed — see errors above.");
  process.exit(1);
}

fs.writeFileSync(path.join(ROOT, "compile-output.json"), JSON.stringify(output));
console.log("\nWrote compile-output.json:");
for (const file of Object.keys(output.contracts)) {
  for (const name of Object.keys(output.contracts[file])) {
    console.log(`  ${file}:${name}`);
  }
}
