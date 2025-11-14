const { expect } = require("chai");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("VLTX step-by-step", function () {
    async function deploy() {
        const [owner, treasury, alice, bob] = await ethers.getSigners();

        const VLTX = await ethers.getContractFactory("VLTX");
        const vltx = await VLTX.deploy("VAULTEX", "VLTX", treasury.address);
        await vltx.waitForDeployment();

        // exclude owner/treasury already set in constructor; set guards
        const now = await time.latest();
        await vltx.setLimits(
            ethers.parseUnits("20000000", 18), // maxTx ~2% of 1B
            ethers.parseUnits("30000000", 18), // maxWallet ~3%
            45,                                 // cooldown seconds
            now + 3600                          // guard window 1h
        );
        await vltx.setSniperBlocks(3);

        return { vltx, owner, treasury, alice, bob };
    }

    it("Step 1: before trading, only excluded addresses can transfer", async () => {
        const { vltx, owner, alice } = await deploy();

        // owner is excluded -> can send setup tokens
        await vltx.transfer(alice.address, ethers.parseUnits("1000", 18));

        // simulate public user tries to transfer while trading disabled
        const vltxAlice = vltx.connect(alice);
        await expect(
            vltxAlice.transfer(owner.address, ethers.parseUnits("1", 18))
        ).to.be.revertedWith("trading disabled");
    });

    it("Step 2: enableTrading -> transfers work (subject to launch guards)", async () => {
        const { vltx, owner, alice } = await deploy();

        // seed alice before enabling (owner is excluded)
        await vltx.transfer(alice.address, ethers.parseUnits("1000", 18));

        await vltx.enableTrading();

        const vltxAlice = vltx.connect(alice);
        await vltxAlice.transfer(owner.address, ethers.parseUnits("10", 18)); // OK now
    });

    it("Step 3: fee cap respected; set buy/sell fees <= 5%", async () => {
        const { vltx } = await deploy();
        await expect(vltx.setFees(600, 0)).to.be.revertedWith("fee>cap"); // >5% blocked
        await vltx.setFees(200, 300); // 2% buy, 3% sell OK
    });

    it("Step 4: blacklist blocks transfers", async () => {
        const { vltx, owner, alice } = await deploy();
        await vltx.enableTrading();
        await vltx.setBlacklist(alice.address, true);
        await expect(
            vltx.connect(owner).transfer(alice.address, 1)
        ).to.be.revertedWith("blacklisted");
    });
});
