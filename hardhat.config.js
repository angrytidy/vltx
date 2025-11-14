require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");

const RPC = process.env.BSC_TESTNET_RPC || "";
const PK = process.env.PRIVATE_KEY || "";
const BSCSCAN = process.env.BSCSCAN_API_KEY || "";

if (!RPC) {
  throw new Error("Missing BSC_TESTNET_RPC in your .env (Hardhat needs a URL string).");
}

module.exports = {
  solidity: {
    version: "0.8.23",
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "paris" },
  },
  networks: {
    bsctest: {
      url: RPC,
      chainId: 97,
      accounts: PK ? [PK] : [],
    },
  },
  etherscan: {
    apiKey: { bscTestnet: BSCSCAN },
  },
};
