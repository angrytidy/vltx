// scripts/test-deploy-vltx.js
const hre = require("hardhat");
require("dotenv").config();
const fs = require("fs");
const path = require("path");

function mustAddr(label, v) {
    if (!v) throw new Error(`${label} is not a valid address: ${v}`);
    try { return hre.ethers.getAddress(v); }
    catch { throw new Error(`${label} is not a valid address: ${v}`); }
}

async function main() {
    const [deployer] = await hre.ethers.getSigners();

    // VLTX constructor: (address initialOwner)
    const ownerRaw =
        process.env.OWNER_ADDRESS ||
        process.env.NEXT_PUBLIC_OWNER_ADDRESS ||
        deployer.address; // fallback: deployer

    const ownerAddr = mustAddr("OWNER_ADDRESS", ownerRaw);

    console.log("Network:", hre.network.name);
    console.log("Deployer:", deployer.address);
    console.log("Initial owner:", ownerAddr);

    const VLTX = await hre.ethers.getContractFactory("VLTX");
    const vltx = await VLTX.deploy(ownerAddr);
    console.log("Deploy tx:", vltx.deploymentTransaction().hash);

    await vltx.waitForDeployment();
    const tokenAddress = await vltx.getAddress();

    console.log("VLTX deployed at:", tokenAddress);
    console.log("name/symbol/decimals:");
    console.log(
        await vltx.name(),
        await vltx.symbol(),
        await vltx.decimals()
    );


    // Save a simple deployments file
    const file = path.join(__dirname, "..", "deployments", `${hre.network.name}-vltx.json`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(
        file,
        JSON.stringify(
            {
                network: hre.network.name,
                token: tokenAddress,
                owner: ownerAddr,
                deployedAt: new Date().toISOString(),
                deployer: deployer.address,
            },
            null,
            2
        )
    );
    console.log("Saved:", file);

    // Show initial balances to avoid confusion
    const supply = await vltx.totalSupply();
    const ownerBal = await vltx.balanceOf(ownerAddr);
    console.log("totalSupply:", supply.toString());
    console.log("owner balance:", ownerBal.toString());
    console.log("NOTE: This VLTX contract mints a fixed 100 * 10^18 at deploy.");
}

main().catch((e) => (console.error(e), process.exitCode = 1));
