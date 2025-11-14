const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

function mustAddr(label, v) {
    if (!v) throw new Error(`${label} missing`);
    return hre.ethers.getAddress(v);
}

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    const token = mustAddr("TOKEN_ADDRESS", process.env.TOKEN_ADDRESS);
    const owner = mustAddr("OWNER_ADDRESS", process.env.OWNER_ADDRESS || deployer.address);

    console.log("Network:", hre.network.name);
    console.log("Deployer:", deployer.address);
    console.log("Token:", token);
    console.log("Initial owner:", owner);

    const Vault = await hre.ethers.getContractFactory("VestingVault");
    const vault = await Vault.deploy(token, owner);
    console.log("Deploy tx:", vault.deploymentTransaction().hash);
    await vault.waitForDeployment();

    const addr = await vault.getAddress();
    console.log("VestingVault deployed at:", addr);
    console.log("vault.token() =", await vault.token());

    const file = path.join(__dirname, "..", "deployments", `${hre.network.name}-vault.json`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ network: hre.network.name, vault: addr, token, owner }, null, 2));
    console.log("Saved:", file);
}

main().catch((e) => (console.error(e), process.exitCode = 1));
