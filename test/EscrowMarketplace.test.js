const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 24 * 60 * 60;
const usd = (n) => ethers.parseUnits(n.toString(), 18);

// Mirrors the Solidity enum.
const Status = { None: 0, Funded: 1, Delivered: 2, Completed: 3, Refunded: 4, Disputed: 5, Resolved: 6 };

describe("EscrowMarketplace", function () {
  async function deployFixture() {
    const [owner, buyer, seller, arbiter, treasury, stranger] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockToken");
    const usdt = await Token.deploy("Test USD", "tUSD", usd(1_000_000));
    await usdt.transfer(buyer.address, usd(10_000));

    const Escrow = await ethers.getContractFactory("EscrowMarketplace");
    // 2.5% fee, 3-day review period.
    const escrow = await Escrow.deploy(await usdt.getAddress(), owner.address, arbiter.address, treasury.address, 250, 3 * DAY);

    await usdt.connect(buyer).approve(await escrow.getAddress(), ethers.MaxUint256);
    return { usdt, escrow, owner, buyer, seller, arbiter, treasury, stranger };
  }

  async function dealFixture() {
    const ctx = await deployFixture();
    const deadline = BigInt(await time.latest()) + BigInt(7 * DAY);
    await ctx.escrow.connect(ctx.buyer).createDeal(ctx.seller.address, usd(1000), deadline);
    return { ...ctx, dealId: 1n, deadline };
  }

  async function deliveredFixture() {
    const ctx = await dealFixture();
    await ctx.escrow.connect(ctx.seller).markDelivered(ctx.dealId);
    return ctx;
  }

  describe("Deployment", function () {
    it("rejects zero addresses and excessive fees", async function () {
      const { usdt, owner, arbiter, treasury } = await loadFixture(deployFixture);
      const Escrow = await ethers.getContractFactory("EscrowMarketplace");
      const token = await usdt.getAddress();
      await expect(Escrow.deploy(ethers.ZeroAddress, owner.address, arbiter.address, treasury.address, 0, DAY))
        .to.be.revertedWithCustomError(Escrow, "ZeroAddress");
      await expect(Escrow.deploy(token, owner.address, arbiter.address, treasury.address, 1001, DAY))
        .to.be.revertedWithCustomError(Escrow, "FeeTooHigh");
    });
  });

  describe("Creating deals", function () {
    it("locks funds and records the deal", async function () {
      const { usdt, escrow, buyer, seller } = await loadFixture(deployFixture);
      const deadline = BigInt(await time.latest()) + BigInt(DAY);

      await expect(escrow.connect(buyer).createDeal(seller.address, usd(500), deadline))
        .to.emit(escrow, "DealCreated")
        .withArgs(1, buyer.address, seller.address, usd(500), deadline);

      expect(await usdt.balanceOf(await escrow.getAddress())).to.equal(usd(500));
      const deal = await escrow.deals(1);
      expect(deal.status).to.equal(Status.Funded);
      expect(deal.feeBps).to.equal(250);
    });

    it("validates input", async function () {
      const { escrow, buyer, seller } = await loadFixture(deployFixture);
      const deadline = BigInt(await time.latest()) + BigInt(DAY);
      await expect(escrow.connect(buyer).createDeal(ethers.ZeroAddress, 1, deadline))
        .to.be.revertedWithCustomError(escrow, "ZeroAddress");
      await expect(escrow.connect(buyer).createDeal(buyer.address, 1, deadline))
        .to.be.revertedWithCustomError(escrow, "InvalidSeller");
      await expect(escrow.connect(buyer).createDeal(seller.address, 0, deadline))
        .to.be.revertedWithCustomError(escrow, "ZeroAmount");
      await expect(escrow.connect(buyer).createDeal(seller.address, 1, 1))
        .to.be.revertedWithCustomError(escrow, "InvalidDeadline");
    });
  });

  describe("Happy path", function () {
    it("buyer confirms delivery: seller paid minus fee", async function () {
      const { usdt, escrow, buyer, seller, treasury, dealId } = await loadFixture(deliveredFixture);
      await expect(escrow.connect(buyer).confirm(dealId))
        .to.emit(escrow, "DealCompleted")
        .withArgs(dealId, usd(975), usd(25));

      expect(await usdt.balanceOf(seller.address)).to.equal(usd(975));
      expect(await usdt.balanceOf(treasury.address)).to.equal(usd(25));
      expect((await escrow.deals(dealId)).status).to.equal(Status.Completed);
    });

    it("anyone can complete the deal after the review period", async function () {
      const { usdt, escrow, seller, stranger, dealId } = await loadFixture(deliveredFixture);
      await expect(escrow.connect(stranger).claimAfterReview(dealId))
        .to.be.revertedWithCustomError(escrow, "ReviewPeriodActive");

      await time.increase(3 * DAY + 1);
      await escrow.connect(stranger).claimAfterReview(dealId);
      expect(await usdt.balanceOf(seller.address)).to.equal(usd(975));
    });

    it("fee changes do not affect existing deals", async function () {
      const { usdt, escrow, buyer, seller, treasury, dealId } = await loadFixture(deliveredFixture);
      await escrow.setFee(1000, treasury.address);
      await escrow.connect(buyer).confirm(dealId);
      expect(await usdt.balanceOf(seller.address)).to.equal(usd(975));
    });
  });

  describe("Access control and state checks", function () {
    it("only the right party can act", async function () {
      const { escrow, buyer, seller, stranger, dealId } = await loadFixture(dealFixture);
      await expect(escrow.connect(buyer).markDelivered(dealId)).to.be.revertedWithCustomError(escrow, "NotSeller");
      await expect(escrow.connect(seller).confirm(dealId)).to.be.revertedWithCustomError(escrow, "NotBuyer");
      await expect(escrow.connect(stranger).openDispute(dealId)).to.be.revertedWithCustomError(escrow, "NotParticipant");
      await expect(escrow.connect(stranger).resolveDispute(dealId, 0)).to.be.revertedWithCustomError(escrow, "NotArbiter");
    });

    it("cannot confirm before delivery or act on unknown deals", async function () {
      const { escrow, buyer, dealId } = await loadFixture(dealFixture);
      await expect(escrow.connect(buyer).confirm(dealId))
        .to.be.revertedWithCustomError(escrow, "WrongStatus")
        .withArgs(Status.Funded);
      await expect(escrow.connect(buyer).confirm(99))
        .to.be.revertedWithCustomError(escrow, "WrongStatus")
        .withArgs(Status.None);
    });

    it("a completed deal cannot be paid twice", async function () {
      const { escrow, buyer, dealId } = await loadFixture(deliveredFixture);
      await escrow.connect(buyer).confirm(dealId);
      await expect(escrow.connect(buyer).confirm(dealId)).to.be.revertedWithCustomError(escrow, "WrongStatus");
      await expect(escrow.claimAfterReview(dealId)).to.be.revertedWithCustomError(escrow, "WrongStatus");
    });
  });

  describe("Refunds", function () {
    it("buyer cancels after the deadline if nothing was delivered", async function () {
      const { usdt, escrow, buyer, dealId, deadline } = await loadFixture(dealFixture);
      await expect(escrow.connect(buyer).cancel(dealId)).to.be.revertedWithCustomError(escrow, "DeadlineNotPassed");

      await time.increaseTo(deadline + 1n);
      await expect(escrow.connect(buyer).cancel(dealId)).to.changeTokenBalance(usdt, buyer, usd(1000));
      expect((await escrow.deals(dealId)).status).to.equal(Status.Refunded);
    });

    it("seller cannot deliver after the deadline", async function () {
      const { escrow, seller, dealId, deadline } = await loadFixture(dealFixture);
      await time.increaseTo(deadline + 1n);
      await expect(escrow.connect(seller).markDelivered(dealId)).to.be.revertedWithCustomError(escrow, "DeadlinePassed");
    });

    it("seller can refund voluntarily", async function () {
      const { usdt, escrow, buyer, seller, dealId } = await loadFixture(dealFixture);
      await expect(escrow.connect(seller).refundBuyer(dealId)).to.changeTokenBalance(usdt, buyer, usd(1000));
    });
  });

  describe("Disputes", function () {
    it("arbiter splits funds; fee only on seller part", async function () {
      const { usdt, escrow, buyer, seller, arbiter, treasury, dealId } = await loadFixture(deliveredFixture);
      await expect(escrow.connect(buyer).openDispute(dealId)).to.emit(escrow, "DisputeOpened").withArgs(dealId, buyer.address);

      // 60% to seller: 600 gross, 15 fee, 585 net; 400 back to buyer.
      await expect(escrow.connect(arbiter).resolveDispute(dealId, 6000))
        .to.emit(escrow, "DisputeResolved")
        .withArgs(dealId, usd(585), usd(400), usd(15));

      expect(await usdt.balanceOf(seller.address)).to.equal(usd(585));
      expect(await usdt.balanceOf(treasury.address)).to.equal(usd(15));
      expect(await usdt.balanceOf(await escrow.getAddress())).to.equal(0);
      expect((await escrow.deals(dealId)).status).to.equal(Status.Resolved);
    });

    it("full refund through arbitration", async function () {
      const { usdt, escrow, buyer, seller, arbiter, dealId } = await loadFixture(dealFixture);
      await escrow.connect(seller).openDispute(dealId);
      await expect(escrow.connect(arbiter).resolveDispute(dealId, 0)).to.changeTokenBalance(usdt, buyer, usd(1000));
    });

    it("disputed deals are frozen", async function () {
      const { escrow, buyer, dealId } = await loadFixture(deliveredFixture);
      await escrow.connect(buyer).openDispute(dealId);
      await time.increase(10 * DAY);
      await expect(escrow.claimAfterReview(dealId)).to.be.revertedWithCustomError(escrow, "WrongStatus");
      await expect(escrow.connect(buyer).confirm(dealId)).to.be.revertedWithCustomError(escrow, "WrongStatus");
    });

    it("buyer cannot dispute after the review period ended", async function () {
      const { escrow, buyer, dealId } = await loadFixture(deliveredFixture);
      await time.increase(3 * DAY + 1);
      await expect(escrow.connect(buyer).openDispute(dealId)).to.be.revertedWithCustomError(escrow, "WrongStatus");
    });

    it("rejects invalid shares", async function () {
      const { escrow, buyer, arbiter, dealId } = await loadFixture(deliveredFixture);
      await escrow.connect(buyer).openDispute(dealId);
      await expect(escrow.connect(arbiter).resolveDispute(dealId, 10_001)).to.be.revertedWithCustomError(escrow, "InvalidShare");
    });
  });

  describe("Admin", function () {
    it("owner manages settings; others cannot", async function () {
      const { escrow, stranger, treasury } = await loadFixture(deployFixture);
      await expect(escrow.setArbiter(stranger.address)).to.emit(escrow, "ArbiterUpdated").withArgs(stranger.address);
      await expect(escrow.setFee(1001, treasury.address)).to.be.revertedWithCustomError(escrow, "FeeTooHigh");
      await expect(escrow.setReviewPeriod(DAY)).to.emit(escrow, "ReviewPeriodUpdated");
      await expect(escrow.connect(stranger).setFee(0, stranger.address))
        .to.be.revertedWithCustomError(escrow, "OwnableUnauthorizedAccount");
    });
  });
});
