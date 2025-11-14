const hre = require("hardhat");

async function main() {
    const [owner] = await hre.ethers.getSigners();
    const TOKEN = process.env.TOKEN_ADDRESS;
    const VAULT = process.env.VAULT_ADDRESS;

    const vltx = await hre.ethers.getContractAt("VLTX", TOKEN, owner);
    const amount = hre.ethers.parseUnits("40", 18);
    console.log("TOKEN:", TOKEN);
    console.log("owner:", owner.address);
    console.log("vault:", VAULT);
    console.log("total supply:", (await vltx.totalSupply()).toString());
    console.log("owner balance before:", (await vltx.balanceOf(owner.address)).toString());

    const tx = await vltx.transfer(VAULT, amount);
    console.log("transfer tx:", tx.hash);
    await tx.wait();

    console.log("vault balance after:", (await vltx.balanceOf(VAULT)).toString());
}
main().catch(e => (console.error(e), process.exitCode = 1));

