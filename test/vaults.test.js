const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("VestingVault", function () {
    it("creates a schedule and allows full immediate claim", async () => {
        const [owner, treasury, marketing] = await ethers.getSigners();

        //
        // 1) Deploy VLTX with the correct constructor:
        //    constructor(string name_, string symbol_, address initialOwner, uint256 initialSupply)
        //
        const VLTX = await ethers.getContractFactory("VLTX");
        const initialSupply = ethers.parseUnits("1000000000", 18n); // 1,000,000,000 VLTX
        const vltx = await VLTX.deploy(
            "VAULTEX",        // name_
            "VLTX",           // symbol_
            treasury.address, // initialOwner
            initialSupply     // initialSupply
        );
        await vltx.waitForDeployment();

        console.log("VLTX deployed at:", await vltx.getAddress());

        //
        // 2) Deploy VestingVault with (token, initialOwner)
        //
        const Vault = await ethers.getContractFactory("VestingVault");
        const vault = await Vault.deploy(
            await vltx.getAddress(), // token_
            owner.address            // initialOwner
        );
        await vault.waitForDeployment();

        const vaultAddress = await vault.getAddress();
        console.log("VestingVault deployed at:", vaultAddress);

        //
        // 👉 IMPORTANT: allow the vault to transfer even before trading is enabled
        //
        await vltx
            .connect(treasury)                // only token owner can call this
            .setLimitsExclusion(vaultAddress, true);

        //
        // 3) Fund vault with 150M VLTX from treasury
        //
        const total = ethers.parseUnits("150000000", 18n); // 150,000,000 VLTX
        await vltx
            .connect(treasury)
            .transfer(vaultAddress, total);

        //
        // 4) Create a schedule that vests immediately:
        //    - start = 0
        //    - cliff = 0
        //    - duration = 1 (so full amount is vested)
        //
        const start = 0;      // uint64
        const cliff = 0;      // uint64
        const duration = 1;   // uint64
        const ROLE_MARKETING = 2; // enum Role { NONE=0, TEAM=1, MARKETING=2 }

        await vault.createSchedule(
            marketing.address,
            total,
            start,
            cliff,
            duration,
            false,           // revocable
            ROLE_MARKETING
        );

        //
        // Helper: read claimable(marketing)
        //
        const claimable = async () =>
            await vault.claimable(marketing.address);

        //
        // 5) Immediately: full amount should be claimable
        //
        const c0 = await claimable();
        expect(c0).to.equal(total);

        //
        // 6) Release: marketing claims tokens
        //
        await vault.connect(marketing).release(marketing.address);

        const bal = await vltx.balanceOf(marketing.address);
        expect(bal).to.equal(total);

        const cAfter = await claimable();
        expect(cAfter).to.equal(0n);

        //
        // 7) Check scheduleOf
        //
        const schedule = await vault.scheduleOf(marketing.address);
        expect(schedule.total).to.equal(total);
        expect(schedule.released).to.equal(bal);
        expect(schedule.revoked).to.equal(false);
    });
});
