/* eslint-disable no-undef */
const { expect } = require("chai");
const { ethers } = require("hardhat");

// ===== helpers =====
const E18 = 10n ** 18n;
const MONTH = 30n * 24n * 60n * 60n;

async function setNextTimestamp(ts) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [Number(ts)]);
    await ethers.provider.send("evm_mine", []);
}

describe("VestingVault (TEAM + MARKETING) — two-role plan", function () {
    async function deployFixture() {
        const [deployer, initialOwner, teamUser, marketingUser] = await ethers.getSigners();

        // --- Deploy your VLTX token (constructor: name, symbol, initialOwner, initialSupply) ---
        const VLTX = await ethers.getContractFactory("VLTX");
        const name = "VAULTEX";
        const symbol = "VLTX";
        const supply = 1_000_000_000n * E18; // 1B * 1e18
        const token = await VLTX.deploy(name, symbol, initialOwner.address, supply);
        await token.waitForDeployment();

        // --- Deploy the VestingVault (constructor: token, initialOwner) ---
        const Vault = await ethers.getContractFactory("VestingVault");
        const vault = await Vault.deploy(await token.getAddress(), initialOwner.address);
        await vault.waitForDeployment();

        // IMPORTANT: exclude the vault so it can transfer before trading is enabled
        const vaddr = await vault.getAddress();
        await token.connect(initialOwner).setLimitsExclusion(vaddr, true);
        await token.connect(initialOwner).setFeeExclusion(vaddr, true);

        // Role wallets for tests
        const TEAM = teamUser.address;
        const MKT = marketingUser.address;

        return {
            deployer, initialOwner, teamUser, marketingUser,
            token, vault, TEAM, MKT, supply
        };
    }

    it("creates TEAM (7% over 7 months from Month 2) and MARKETING (stream from Month 2), and pays out correctly", async () => {
        const {
            initialOwner, token, vault, TEAM, MKT, supply
        } = await deployFixture();

        // ----- parameters -----
        const teamTotal = (supply * 7n) / 100n;   // 7% = 70,000,000e18
        const mktTotal = (supply * 33n) / 100n;  // 33% = 330,000,000e18
        const mktTGE = (mktTotal * 3n) / 100n; // 3% of marketing bucket = 9,900,000e18
        const mktStream = mktTotal - mktTGE;      // 320,100,000e18

        // Simulated TGE ~ 5 minutes from now
        const now = await ethers.provider.getBlock("latest");
        const TGE = BigInt(now.timestamp) + 300n;

        // ----- fund the vault with tokens to stream -----
        await token.connect(initialOwner).transfer(await vault.getAddress(), teamTotal + mktStream);

        // Send the Marketing TGE kick-off directly to MKT wallet (not via vault)
        await token.connect(initialOwner).transfer(MKT, mktTGE);

        // ----- create schedules -----
        // TEAM: single linear stream starting Month 2 for 7 months
        await vault.connect(initialOwner).createSchedule(
            TEAM,
            teamTotal,
            Number(TGE),                   // start (reference)
            Number(TGE + 1n * MONTH),      // cliff => Month 2
            Number(7n * MONTH),            // duration => 7 months linear
            false,                         // revocable
            1                              // Role.TEAM (enum: 0=NONE,1=TEAM,2=MARKETING)
        );

        // MARKETING: stream (remaining 97% of 33%) starting Month 2 for 18 months
        await vault.connect(initialOwner).createSchedule(
            MKT,
            mktStream,
            Number(TGE + 1n * MONTH),      // start
            Number(TGE + 1n * MONTH),      // cliff = start (Month 2)
            Number(18n * MONTH),           // duration 18m
            false,
            2                              // Role.MARKETING
        );

        // --- Before Month 2: nothing claimable for either stream ---
        await setNextTimestamp(TGE + (15n * 24n * 60n * 60n)); // +15 days
        expect(await vault.claimable(TEAM)).to.equal(0n);
        expect(await vault.claimable(MKT)).to.equal(0n);

        // --- Halfway through Month 2: TEAM and MKT have some claimable ---
        await setNextTimestamp(TGE + 1n * MONTH + (15n * 24n * 60n * 60n)); // Month2 + ~15 days

        const teamClaimMid = await vault.claimable(TEAM);
        expect(teamClaimMid).to.be.gt(0n);

        const mktClaimMid = await vault.claimable(MKT);
        expect(mktClaimMid).to.be.gt(0n);

        // TEAM expected mid-month ≈ teamTotal * (elapsed / (7 months))
        const approxTeamMid = (teamTotal * (15n * 24n * 60n * 60n)) / (7n * MONTH);
        expect(teamClaimMid).to.be.closeTo(approxTeamMid, approxTeamMid / 40n); // ~2.5% tolerance

        // MARKETING expected mid-month ≈ mktStream * (elapsed / (18 months))
        const approxMktMid = (mktStream * (15n * 24n * 60n * 60n)) / (18n * MONTH);
        expect(mktClaimMid).to.be.closeTo(approxMktMid, approxMktMid / 40n);

        // --- Release TEAM from the vault (sanity only; don't assert exact mid due to per-second drift) ---
        const teamBefore = await token.balanceOf(TEAM);
        await vault.release(TEAM);
        const teamAfter = await token.balanceOf(TEAM);
        expect(teamAfter).to.be.gt(teamBefore);

        // --- Advance to end of TEAM schedule and finish (assert exact total) ---
        await setNextTimestamp(TGE + 1n * MONTH + 7n * MONTH + 10n); // Month2 + 7 months + small delta
        await vault.release(TEAM);
        const teamFinalBal = await token.balanceOf(TEAM);
        expect(teamFinalBal).to.equal(teamTotal); // ✅ exact

        // --- Marketing stream continues for 18 months from Month2 ---
        await setNextTimestamp(TGE + 1n * MONTH + 9n * MONTH); // Month2 + 9 months
        const mktHalfClaim = await vault.claimable(MKT);
        const approxMktHalf = mktStream / 2n;
        expect(mktHalfClaim).to.be.closeTo(approxMktHalf, approxMktHalf / 40n);

        // Release marketing mid-way (sanity)
        const mktBefore = await token.balanceOf(MKT);
        await vault.release(MKT);
        const mktAfter = await token.balanceOf(MKT);
        expect(mktAfter).to.be.gt(mktBefore);

        // Go to end of 18m stream and finish (assert exact bucket total)
        await setNextTimestamp(TGE + 1n * MONTH + 18n * MONTH + 10n);
        await vault.release(MKT);

        // ✅ Final check: marketing = TGE kick + full stream
        const mktFinalBal = await token.balanceOf(MKT);
        expect(mktFinalBal).to.equal(mktTotal);
    });

    it("enumeration and views return 2 beneficiaries and correct roles/schedules", async () => {
        const {
            initialOwner, token, vault, TEAM, MKT, supply
        } = await deployFixture();

        const teamTotal = (supply * 7n) / 100n;
        const mktTotal = (supply * 33n) / 100n;
        const mktTGE = (mktTotal * 3n) / 100n;
        const mktStream = mktTotal - mktTGE;

        const now = await ethers.provider.getBlock("latest");
        const TGE = BigInt(now.timestamp) + 60n;

        await token.connect(initialOwner).transfer(await vault.getAddress(), teamTotal + mktStream);
        await token.connect(initialOwner).transfer(MKT, mktTGE);

        // TEAM schedule
        await vault.connect(initialOwner).createSchedule(
            TEAM,
            teamTotal,
            Number(TGE),
            Number(TGE + 1n * MONTH),
            Number(7n * MONTH),
            false,
            1 // TEAM
        );

        // MARKETING stream
        await vault.connect(initialOwner).createSchedule(
            MKT,
            mktStream,
            Number(TGE + 1n * MONTH),
            Number(TGE + 1n * MONTH),
            Number(18n * MONTH),
            false,
            2 // MARKETING
        );

        const count = await vault.getBeneficiaryCount();
        expect(count).to.equal(2n);

        // roles
        const teamRole = await vault.roleOf(TEAM);
        const mktRole = await vault.roleOf(MKT);
        expect(teamRole).to.equal(1); // Role.TEAM
        expect(mktRole).to.equal(2);  // Role.MARKETING

        // schedules (no role inside tuple)
        const teamSched = await vault.scheduleOf(TEAM);
        const mktSched = await vault.scheduleOf(MKT);

        // tuple: total, released, start, cliff, duration, revocable, revoked
        expect(teamSched[0]).to.equal(teamTotal);
        expect(mktSched[0]).to.equal(mktStream);
        expect(teamSched[6]).to.equal(false); // not revoked
        expect(mktSched[6]).to.equal(false);  // not revoked
    });
});
