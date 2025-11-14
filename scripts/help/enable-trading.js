// scripts/token/enable-trading.js
const hre = require("hardhat");

async function main() {
    const { ethers } = hre;
    const [owner] = await ethers.getSigners();

    const TOKEN = process.env.TOKEN_ADDRESS;
    if (!TOKEN) throw new Error("Set TOKEN_ADDRESS");

    const token = await ethers.getContractAt("VLTX", TOKEN, owner);

    console.log("Owner:", owner.address);
    console.log("Token:", TOKEN);

    const tx = await token.enableTrading(); // or setTradingEnabled(true) depending on your function
    console.log("enableTrading tx:", tx.hash);
    await tx.wait();

    console.log("✅ Trading enabled");
}

main().catch((e) => {
    console.error(e);
    process.exitCode = 1;
});
