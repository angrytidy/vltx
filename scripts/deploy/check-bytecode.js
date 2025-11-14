const hre = require("hardhat");

async function main() {
    const { ethers, artifacts } = hre;
    const VAULT = process.env.VAULT_ADDRESS;
    if (!VAULT) throw new Error("Set VAULT_ADDRESS");

    const artifact = await artifacts.readArtifact("VestingVault");
    const localDeployed = artifact.deployedBytecode;
    const onchain = await ethers.provider.getCode(VAULT);

    console.log("Local deployed bytecode length:", localDeployed.length);
    console.log("On-chain bytecode length:      ", onchain.length);

    const localHash = ethers.keccak256(localDeployed);
    const onchainHash = ethers.keccak256(onchain);

    console.log("Local bytecode hash:   ", localHash);
    console.log("On-chain bytecode hash:", onchainHash);
}

main().catch((e) => {
    console.error(e);
    process.exitCode = 1;
});
