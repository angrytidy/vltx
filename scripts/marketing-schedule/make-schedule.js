const hre = require("hardhat");

// 30-day month in seconds (use your policy if different)
const MONTH = 30 * 24 * 60 * 60;

async function main() {
    const [owner] = await hre.ethers.getSigners();

    const VAULT = process.env.VAULT_ADDRESS;                 // VestingVault
    const TOKEN = process.env.TOKEN_ADDRESS;                 // VLTX (for TGE)
    const MKT_TGE = process.env.MARKETING_ADDR_TGE;          // wallet for 1% in first month
    const MKT_STREAM = process.env.MARKETING_ADDR_STREAM;    // wallet for 32% over 18 months from month 3
    const TOTAL_MARKETING = process.env.TOTAL_MARKETING;     // tokens (not wei), e.g. "33" or "3300000"

    if (!VAULT || !TOKEN) throw new Error("Set VAULT_ADDRESS and TOKEN_ADDRESS");
    if (!MKT_TGE || !MKT_STREAM) throw new Error("Set MARKETING_ADDR_TGE and MARKETING_ADDR_STREAM");
    if (hre.ethers.getAddress(MKT_TGE) === hre.ethers.getAddress(MKT_STREAM))
        throw new Error("MARKETING_ADDR_TGE and MARKETING_ADDR_STREAM must be different addresses");
    if (!TOTAL_MARKETING) throw new Error("Set TOTAL_MARKETING (tokens, not wei)");

    const vault = await hre.ethers.getContractAt("VestingVault", VAULT, owner);
    const token = await hre.ethers.getContractAt("VLTX", TOKEN, owner);

    // --- Read real TGE from token ---
    const enabled = await token.tradingEnabled();
    if (!enabled) throw new Error("Trading not enabled yet — run this after enableTrading()");
    const tge = Number(await token.tradingEnabledAt());

    // --- Amounts ---
    const decimals = await token.decimals();
    const totalWei = hre.ethers.parseUnits(TOTAL_MARKETING, decimals);
    const amt1 = totalWei / 100n;               // 1%
    const amt2 = (totalWei * 32n) / 100n;       // 32%

    // --- Phase 1: 1% over first month from TGE ---
    const cliff1 = tge;              // start at TGE
    const duration1 = MONTH;         // linear across first month
    console.log("Phase1: 1% over 1 month =>", amt1.toString(), "to", MKT_TGE);
    let tx = await vault.setupMarketingStream(amt1, cliff1, duration1, MKT_TGE);
    console.log("phase1 tx:", tx.hash); await tx.wait();

    // --- Phase 2: 32% over 18 months, starting month 3 ---
    const cliff2 = tge + 2 * MONTH;  // start of month 3
    const duration2 = 18 * MONTH;    // 18 months linear
    console.log("Phase2: 32% over 18 months =>", amt2.toString(), "to", MKT_STREAM);
    tx = await vault.setupMarketingStream(amt2, cliff2, duration2, MKT_STREAM);
    console.log("phase2 tx:", tx.hash); await tx.wait();

    console.log("✅ Marketing schedules set. TGE =", tge);
}

main().catch((e) => (console.error(e), process.exitCode = 1));
