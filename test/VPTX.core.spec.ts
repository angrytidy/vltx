const { expect } = require("chai");
const { ethers } = require("hardhat");

const BPS_DEN = 10_000n;

async function increaseTime(secs) {
    await ethers.provider.send("evm_increaseTime", [Number(secs)]);
    await ethers.provider.send("evm_mine", []);
}

async function mineBlocks(n) {
    for (let i = 0; i < n; i++) {
        await ethers.provider.send("evm_mine", []);
    }
}

describe("VLTX Core", function () {
    async function deploy() {
        const [deployer, owner, user, treasury, pairEOA, another] = await ethers.getSigners();
        const VLTX = await ethers.getContractFactory("VLTX");
        const name = "VAULTEX";
        const symbol = "VLTX";
        const initialSupply = ethers.parseEther("1000000000"); // 1B

        const vltx = await VLTX.deploy(name, symbol, owner.address, initialSupply);
        await vltx.waitForDeployment();

        return { vltx, deployer, owner, user, treasury, pairEOA, another, initialSupply };
    }

    it("deploys with correct initial state", async () => {
        const { vltx, owner, initialSupply } = await deploy();
        expect(await vltx.name()).to.eq("VAULTEX");
        expect(await vltx.symbol()).to.eq("VLTX");
        expect(await vltx.balanceOf(owner.address)).to.eq(initialSupply);
        expect(await vltx.buyFeeBps()).to.eq(0);
        expect(await vltx.sellFeeBps()).to.eq(0);
    });

    it("prevents public transfers before trading unless excluded", async () => {
        const { vltx, owner, user } = await deploy();
        // owner (excluded) can send pre-launch
        await vltx.connect(owner).transfer(user.address, ethers.parseEther("1"));

        // non-excluded sender cannot send pre-launch
        await expect(
            vltx.connect(user).transfer(owner.address, ethers.parseEther("0.1"))
        ).to.be.revertedWith("Trading not enabled");
    });


    it("enables trading once and records timestamps/blocks", async () => {
        const { vltx, owner } = await deploy();
        await vltx.connect(owner).enableTrading();
        expect(await vltx.tradingEnabled()).to.eq(true);
        expect(await vltx.tradingEnabledAt()).to.be.gt(0);
        expect(await vltx.tradingEnabledBlock()).to.be.gt(0);
        await expect(vltx.connect(owner).enableTrading()).to.be.revertedWith("Already enabled");
    });

    it("respects maxTx and maxWallet after trading enabled", async () => {
        const { vltx, owner, user, another } = await deploy();

        await vltx.connect(owner).enableTrading();
        await vltx.connect(owner).setLaunchParams(200, 300, 0, 0); // 2% / 3% / 0 / 0

        const total = await vltx.totalSupply();
        const maxTx = (total * 200n) / 10000n;       // 2%
        const maxWallet = (total * 300n) / 10000n;   // 3%

        // Seed `another` close to the cap using the EXCLUDED owner (bypasses limits)
        await vltx.connect(owner).transfer(another.address, maxWallet - 1n);

        // Now a NON-EXCLUDED sender triggers maxWallet with a tiny amount (<= maxTx)
        await vltx.connect(owner).transfer(user.address, maxTx); // give user some tokens to send
        await expect(
            vltx.connect(user).transfer(another.address, 2n) // small push over the cap
        ).to.be.revertedWith("maxWallet");

        // And independently prove maxTx hits from a non-excluded sender:
        await expect(
            vltx.connect(user).transfer(another.address, maxTx + 1n)
        ).to.be.revertedWith("maxTx");
    });



    it("enforces cooldown between trades when set", async () => {
        const { vltx, owner, user, another } = await deploy();
        await vltx.connect(owner).enableTrading();
        await vltx.connect(owner).setLaunchParams(200, 300, 45, 0); // 45s cooldown

        // Seed USER from owner (bypass limits)
        const amt = ethers.parseEther("1");
        await vltx.connect(owner).transfer(user.address, amt * 3n);

        // USER sends twice within cooldown → second must revert
        await vltx.connect(user).transfer(another.address, amt);
        await expect(
            vltx.connect(user).transfer(another.address, amt)
        ).to.be.revertedWith("cooldown");

        // advance time and try again
        await ethers.provider.send("evm_increaseTime", [45]);
        await ethers.provider.send("evm_mine", []);
        await vltx.connect(user).transfer(another.address, amt); // ok
    });


    // in test/VPTX.core.spec.ts (sniper test body)
    it("sniper blocks: only EOAs may buy during first N blocks", async () => {
        const { vltx, owner, pairEOA, another } = await deploy();

        await vltx.connect(owner).setAMMPair(pairEOA.address, true);

        // make the window big so setup txs don't push past it
        await vltx.connect(owner).setLaunchParams(200, 300, 0, 100);
        await vltx.connect(owner).enableTrading();

        // seed pair so it can "sell" (simulate a buy)
        await vltx.connect(owner).transfer(pairEOA.address, ethers.parseEther("1"));

        // EOA buy: should pass
        await vltx.connect(pairEOA).transfer(another.address, 1n);

        // Contract buy: should revert
        const Receiver = await ethers.getContractFactory("ReceiverMock");
        const receiver = await Receiver.deploy();
        await receiver.waitForDeployment();

        await expect(
            vltx.connect(pairEOA).transfer(await receiver.getAddress(), 1n)
        ).to.be.revertedWith("EOA-only in sniperBlocks");
    });

    it("fees: cap ≤5%, earliest enable time, receiver routing, exclusions", async () => {
        const { vltx, owner, treasury, pairEOA, another } = await deploy();

        // 0) Setup
        await vltx.connect(owner).setFeeReceiver(treasury.address);
        const blk = await ethers.provider.getBlock("latest");
        await vltx.connect(owner).setEarliestFeeEnableAt(blk.timestamp + 60);

        await vltx.connect(owner).setAMMPair(pairEOA.address, true);
        await vltx.connect(owner).setLaunchParams(200, 300, 0, 0);
        await vltx.connect(owner).enableTrading();

        // 1) Cap + earliest-time guard
        await expect(vltx.connect(owner).setFees(400, 200)).to.be.revertedWith("Fee cap");
        await expect(vltx.connect(owner).setFees(100, 200)).to.be.revertedWith("Too early");

        // 2) Enable fees after time passes
        await ethers.provider.send("evm_increaseTime", [60]);
        await ethers.provider.send("evm_mine", []);
        await vltx.connect(owner).setFees(100, 200); // buy=1%, sell=2%

        // 3) Seed pair (owner is excluded; simple transfer)
        const amt = ethers.parseEther("1");
        await vltx.connect(owner).transfer(pairEOA.address, amt);
        expect(await vltx.balanceOf(pairEOA.address)).to.eq(amt);

        // 4) BUY path: pair -> EOA takes 1% fee to treasury
        const t0 = await vltx.balanceOf(treasury.address);
        const r0 = await vltx.balanceOf(another.address);

        await vltx.connect(pairEOA).transfer(another.address, amt);

        const t1 = await vltx.balanceOf(treasury.address);
        const r1 = await vltx.balanceOf(another.address);
        const feeBuy = amt / 100n; // 1%

        expect(r1 - r0).to.eq(amt - feeBuy);
        expect(t1 - t0).to.eq(feeBuy);

        // 5) Exclude receiver from fees, seed pair again, then BUY shows no fee
        await vltx.connect(owner).setFeeExclusion(another.address, true);
        await vltx.connect(owner).transfer(pairEOA.address, amt); // top up pair again
        const t2 = await vltx.balanceOf(treasury.address);

        await vltx.connect(pairEOA).transfer(another.address, amt);

        const t3 = await vltx.balanceOf(treasury.address);
        expect(t3 - t2).to.eq(0n);
    });

});
