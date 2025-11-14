// scripts/deploy/preflight.js
const hre = require("hardhat");

async function main() {
    const { ethers } = hre;
    const [signer] = await ethers.getSigners();

    const VAULT = process.env.VAULT_ADDRESS;
    const MKT_TGE = process.env.MARKETING_ADDR_TGE;
    const MKT_STREAM = process.env.MARKETING_ADDR_STREAM;

    if (!VAULT) throw new Error("Set VAULT_ADDRESS");

    const vault = await ethers.getContractAt("VestingVault", VAULT, signer);
    const onChainOwner = await vault.owner();

    console.log({
        defaultSigner: signer.address,
        onChainOwner,
    });

    // Also show marketing config if any
    let mktAddr = ethers.ZeroAddress;
    try {
        mktAddr = await vault.MKT_ADDR();
    } catch {
        // older vaults may not have this
    }
    console.log("MKT_ADDR():", mktAddr);

    const addrs = [
        { label: "signer", addr: signer.address },
        MKT_TGE && { label: "MKT_TGE", addr: MKT_TGE },
        MKT_STREAM && { label: "MKT_STREAM", addr: MKT_STREAM },
    ].filter(Boolean);

    for (const { label, addr } of addrs) {
        console.log(`\nChecking ${label}: ${addr}`);

        // roleOf
        try {
            const role = await vault.roleOf(addr);
            console.log("  roleOf:", role.toString());
        } catch (e) {
            console.log("  roleOf reverted:", e.message || e);
        }

        // raw mapping getter – safe even if no schedule
        try {
            const raw = await vault.schedules(addr);
            console.log("  schedules(addr):", raw);
        } catch (e) {
            console.log("  schedules(addr) reverted:", e.message || e);
        }

        // scheduleOf – may revert if no schedule; just log instead of crashing
        try {
            const sched = await vault.scheduleOf(addr);
            console.log("  scheduleOf(addr):", sched);
        } catch {
            console.log("  scheduleOf(addr): <no schedule / reverted>");
        }
    }
}

main().catch((e) => {
    console.error(e);
    process.exitCode = 1;
});
