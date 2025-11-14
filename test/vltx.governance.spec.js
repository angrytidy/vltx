const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("VLTX governance locks", function () {
    it("locks limits and blocks future changes", async function () {
        const [owner] = await ethers.getSigners();
        const VLTX = await ethers.getContractFactory("VLTX");
        const vltx = await VLTX.deploy("VAULTEX", "VLTX", owner.address, ethers.parseUnits("1000000000", 18));
        await vltx.waitForDeployment();

        // change once (should work)
        await (await vltx.setLaunchParams(300, 400, 30, 2)).wait();

        // lock
        await (await vltx.lockLimitsForever()).wait();

        // now any change should revert
        await expect(vltx.setLaunchParams(200, 300, 45, 3)).to.be.revertedWith("LIMITS_LOCKED");
        await expect(vltx.setLimitsExclusion(owner.address, true)).to.be.revertedWith("LIMITS_LOCKED");
    });
});
