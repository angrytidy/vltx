// scripts/marketing-schedule/test-make-schedule.js
const hre = require("hardhat");

// "Test month" = 60 seconds (fast demo)
const TEST_MONTH = 60; // 1 minute

async function main() {
    const { ethers } = hre;
    const [owner] = await ethers.getSigners();

    const VAULT = process.env.VAULT_ADDRESS;
    const TOKEN = process.env.TOKEN_ADDRESS;
    const MKT_TGE = process.env.MARKETING_ADDR_TGE;
    const MKT_STREAM = process.env.MARKETING_ADDR_STREAM;
    const TOTAL_MARKETING = process.env.TOTAL_MARKETING;

    if (!VAULT) throw new Error("Set VAULT_ADDRESS");
    if (!MKT_TGE || !MKT_STREAM) {
        throw new Error("Set MARKETING_ADDR_TGE and MARKETING_ADDR_STREAM");
    }
    if (ethers.getAddress(MKT_TGE) === ethers.getAddress(MKT_STREAM)) {
        throw new Error(
            "MARKETING_ADDR_TGE and MARKETING_ADDR_STREAM must be different addresses"
        );
    }
    if (!TOTAL_MARKETING) {
        throw new Error("Set TOTAL_MARKETING (tokens, not wei)");
    }

    const vault = await ethers.getContractAt("VestingVault", VAULT, owner);

    // --- Owner sanity check ---
    const vaultOwner = await vault.owner().catch(() => "no owner()");
    console.log("\nVault owner():", vaultOwner);

    // --- Check existing marketing config ---
    let existingMktAddr = ethers.ZeroAddress;
    try {
        existingMktAddr = await vault.MKT_ADDR();
    } catch (e) {
        console.warn("Could not read MKT_ADDR():", e);
    }
    console.log("Existing MKT_ADDR():", existingMktAddr);

    // If marketing already configured to a different address, warn & stop
    if (
        existingMktAddr !== ethers.ZeroAddress &&
        existingMktAddr.toLowerCase() !== MKT_TGE.toLowerCase()
    ) {
        console.error(
            "\n❌ Vault already has a marketing address set:",
            existingMktAddr,
            "\n   This likely means setupMarketingStream was already called once\n" +
            "   and cannot be called again with a different address.\n"
        );
        process.exit(1);
    }

    // Optional: check schedule for existing marketing addr
    if (existingMktAddr !== ethers.ZeroAddress) {
        try {
            const sched = await vault.scheduleOf(existingMktAddr);
            console.log("Existing marketing scheduleOf(MKT_ADDR):", sched);
        } catch (e) {
            console.warn("Could not read scheduleOf(existing MKT_ADDR):", e);
        }
    }

    // --- Token + decimals ---
    if (!TOKEN) throw new Error("Set TOKEN_ADDRESS (VLTX)");
    const token = await ethers.getContractAt("VLTX", TOKEN, owner);
    const decimals = Number(await token.decimals());
    console.log("\nToken:", TOKEN, "decimals:", decimals);

    // --- Amounts ---
    const totalWei = ethers.parseUnits(TOTAL_MARKETING, decimals);
    const amt1 = totalWei / 100n;          // 1%
    const amt2 = (totalWei * 32n) / 100n;  // 32%

    console.log("Total marketing (wei):", totalWei.toString());
    console.log("Amt1 (1%):            ", amt1.toString());
    console.log("Amt2 (32%):           ", amt2.toString());

    // --- Check vault has tokens ---
    const vaultBal = await token.balanceOf(VAULT);
    console.log("Vault VLTX balance:   ", vaultBal.toString());

    // --- Time setup (TEST) ---
    const now = Math.floor(Date.now() / 1000);
    const tge = now;               // just for log
    const baseStart = now + 30;    // start in 30s to avoid start < block.timestamp

    // -------- Phase 1: 1% over 60s --------
    const cliff1 = baseStart;
    const duration1 = TEST_MONTH;

    console.log(
        "\nTEST Phase1: 1% over 60s =>",
        amt1.toString(),
        "to",
        MKT_TGE,
        "| start:",
        cliff1,
        "duration:",
        duration1
    );

    try {
        await vault.setupMarketingStream.staticCall(
            amt1,
            cliff1,
            duration1,
            MKT_TGE
        );
    } catch (e) {
        console.error("staticCall failed for Phase1:", e);
        console.error(
            "\nLikely causes inside VestingVault.setupMarketingStream:\n" +
            "  - marketing stream already initialized (MKT_ADDR != 0)\n" +
            "  - some invariant like `require(total > 0)`, `require(duration > 0)`, or\n" +
            "    `require(startCliff >= block.timestamp)` failing (but values look OK).\n" +
            "If MKT_ADDR is non-zero, you probably need a fresh vault deployment for a new test.\n"
        );
        process.exit(1);
    }

    let tx = await vault.setupMarketingStream(amt1, cliff1, duration1, MKT_TGE);
    console.log("Phase1 tx:", tx.hash);
    await tx.wait();
    console.log("✅ Phase1 stream created");

    // -------- Phase 2: 32% over 18 * 60s (starting 'month 3') --------
    const cliff2 = baseStart + 2 * TEST_MONTH; // after 2 'months'
    const duration2 = 18 * TEST_MONTH;         // 18 'months'

    console.log(
        "\nTEST Phase2: 32% over 18*60s =>",
        amt2.toString(),
        "to",
        MKT_STREAM,
        "| start:",
        cliff2,
        "duration:",
        duration2
    );

    try {
        await vault.setupMarketingStream.staticCall(
            amt2,
            cliff2,
            duration2,
            MKT_STREAM
        );
    } catch (e) {
        console.error("staticCall failed for Phase2:", e);
        process.exit(1);
    }

    tx = await vault.setupMarketingStream(amt2, cliff2, duration2, MKT_STREAM);
    console.log("Phase2 tx:", tx.hash);
    await tx.wait();
    console.log("✅ Phase2 stream created");

    console.log("\n✅ TEST schedules set. tge (test) =", tge);
}

main().catch((e) => {
    console.error(e);
    process.exitCode = 1;
});
