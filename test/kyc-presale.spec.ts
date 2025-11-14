const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const e18 = (n) => ethers.parseUnits(n, 18);

describe("KYC gating (presale)", function () {
    it("blocks non-KYC buy, allows after setKYC", async function () {
        const [admin, operator, treasury, user] = await ethers.getSigners();

        // KYCRegistry(admin = DEFAULT_ADMIN, operator = KYC_OPERATOR)
        const KYC = await ethers.getContractFactory("KYCRegistry");
        const kyc = await KYC.deploy(admin.address, operator.address);
        await kyc.waitForDeployment();

        // Token (mint to treasury)
        const Token = await ethers.getContractFactory("VLTX");
        const token = await Token.deploy(
            "VAULTEX",
            "VLTX",
            treasury.address,
            e18("1000000000")
        );
        await token.waitForDeployment();

        // Presale params
        const now = (await ethers.provider.getBlock("latest")).timestamp;
        const start = now + 5;
        const end = start + 3600;
        const rate = e18("100000"); // 1 BNB => 100k tokens
        const hardCap = ethers.parseEther("10");
        const minC = ethers.parseEther("0.5");
        const maxC = ethers.parseEther("3");

        // Presale
        const Presale = await ethers.getContractFactory("KycPresale");
        const presale = await Presale.deploy(
            admin.address,
            await kyc.getAddress(),
            await token.getAddress(),
            rate,
            start,
            end,
            hardCap,
            minC,
            maxC
        );
        await presale.waitForDeployment();

        // move time to start
        await network.provider.send("evm_setNextBlockTimestamp", [start + 1]);
        await network.provider.send("evm_mine");

        // non-KYC reverts
        await expect(
            presale.connect(user).buy({ value: ethers.parseEther("1") })
        ).to.be.revertedWith("KYC_REQUIRED");

        // approve user
        await kyc.connect(operator).setKYC(user.address, true, "ipfs://case-123");

        // now succeeds
        await expect(
            presale.connect(user).buy({ value: ethers.parseEther("1") })
        ).to.emit(presale, "Bought");
    });
});
