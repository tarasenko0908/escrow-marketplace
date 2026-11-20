// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EscrowMarketplace
 * @notice Escrow for deals between a buyer and a seller paid in a stablecoin (e.g. USDT/USDC).
 *         Suitable for freelance work, marketplaces and delivery services.
 *
 * Deal lifecycle:
 *
 *   Funded ──(seller: markDelivered)──► Delivered ──(buyer: confirm | anyone after review period)──► Completed
 *     │                                    │
 *     ├──(seller: refundBuyer)──► Refunded │
 *     ├──(buyer: cancel after deadline)──► Refunded
 *     │                                    │
 *     └────────(buyer or seller: openDispute)────────► Disputed ──(arbiter: resolveDispute)──► Resolved
 *
 *  - The buyer locks the payment when creating a deal.
 *  - If the seller never delivers before the deadline, the buyer can cancel and get a full refund.
 *  - After delivery the buyer has `reviewPeriod` to confirm or dispute; silence counts as acceptance,
 *    so sellers can't be held hostage by an unresponsive buyer.
 *  - Disputes are resolved by the platform arbiter, who can split the funds in any proportion.
 *  - A platform fee (in basis points) is taken only from the seller's payout.
 */
contract EscrowMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Funded,
        Delivered,
        Completed,
        Refunded,
        Disputed,
        Resolved
    }

    struct Deal {
        address buyer;
        address seller;
        uint256 amount;       // escrowed amount
        uint64 deadline;      // seller must deliver before this time
        uint64 deliveredAt;   // set by markDelivered
        uint16 feeBps;        // fee snapshot at creation time, so later fee changes don't affect the deal
        Status status;
    }

    /// @notice Max fee: 10%.
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint16 private constant BPS = 10_000;

    /// @notice Payment token (stablecoin).
    IERC20 public immutable paymentToken;

    /// @notice Address allowed to resolve disputes.
    address public arbiter;

    /// @notice Address that receives platform fees.
    address public feeRecipient;

    /// @notice Platform fee in basis points (100 = 1%).
    uint16 public feeBps;

    /// @notice How long the buyer has to review a delivery before it auto-completes.
    uint64 public reviewPeriod;

    /// @notice All deals by id (ids start at 1).
    mapping(uint256 dealId => Deal) public deals;

    uint256 public dealCount;

    event DealCreated(uint256 indexed dealId, address indexed buyer, address indexed seller, uint256 amount, uint64 deadline);
    event DealDelivered(uint256 indexed dealId);
    event DealCompleted(uint256 indexed dealId, uint256 sellerPayout, uint256 fee);
    event DealRefunded(uint256 indexed dealId, uint256 amount);
    event DisputeOpened(uint256 indexed dealId, address indexed by);
    event DisputeResolved(uint256 indexed dealId, uint256 toSeller, uint256 toBuyer, uint256 fee);
    event ArbiterUpdated(address arbiter);
    event FeeUpdated(uint16 feeBps, address feeRecipient);
    event ReviewPeriodUpdated(uint64 reviewPeriod);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSeller();
    error InvalidDeadline();
    error FeeTooHigh();
    error InvalidShare();
    error WrongStatus(Status current);
    error NotBuyer();
    error NotSeller();
    error NotParticipant();
    error NotArbiter();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error ReviewPeriodActive();

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }

    constructor(
        IERC20 paymentToken_,
        address owner_,
        address arbiter_,
        address feeRecipient_,
        uint16 feeBps_,
        uint64 reviewPeriod_
    ) Ownable(owner_) {
        if (address(paymentToken_) == address(0) || arbiter_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        paymentToken = paymentToken_;
        arbiter = arbiter_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        reviewPeriod = reviewPeriod_;
    }

    // ─────────────────────────────── Buyer ───────────────────────────────

    /**
     * @notice Creates a deal and locks `amount` tokens. Caller must approve this contract first.
     * @param seller Who will be paid on completion.
     * @param amount Payment amount.
     * @param deadline Timestamp by which the seller must mark the deal as delivered.
     */
    function createDeal(address seller, uint256 amount, uint64 deadline) external nonReentrant returns (uint256 dealId) {
        if (seller == address(0)) revert ZeroAddress();
        if (seller == msg.sender) revert InvalidSeller();
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        dealId = ++dealCount;
        deals[dealId] = Deal({
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            deadline: deadline,
            deliveredAt: 0,
            feeBps: feeBps,
            status: Status.Funded
        });

        // Pull funds last; the deal is already recorded and nonReentrant guards the call.
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        emit DealCreated(dealId, msg.sender, seller, amount, deadline);
    }

    /// @notice Buyer accepts the delivery and releases payment to the seller.
    function confirm(uint256 dealId) external nonReentrant {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.buyer) revert NotBuyer();
        _requireStatus(d, Status.Delivered);
        _complete(dealId, d);
    }

    /// @notice Buyer cancels a deal the seller didn't deliver in time and gets a full refund.
    function cancel(uint256 dealId) external nonReentrant {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.buyer) revert NotBuyer();
        _requireStatus(d, Status.Funded);
        if (block.timestamp <= d.deadline) revert DeadlineNotPassed();
        _refund(dealId, d);
    }

    // ─────────────────────────────── Seller ───────────────────────────────

    /// @notice Seller marks the work/order as delivered; starts the buyer review period.
    function markDelivered(uint256 dealId) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.seller) revert NotSeller();
        _requireStatus(d, Status.Funded);
        if (block.timestamp > d.deadline) revert DeadlinePassed();

        d.status = Status.Delivered;
        d.deliveredAt = uint64(block.timestamp);
        emit DealDelivered(dealId);
    }

    /// @notice Seller voluntarily refunds the buyer (e.g. can't fulfil the order).
    function refundBuyer(uint256 dealId) external nonReentrant {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.seller) revert NotSeller();
        if (d.status != Status.Funded && d.status != Status.Delivered) revert WrongStatus(d.status);
        _refund(dealId, d);
    }

    // ─────────────────────────────── Anyone ───────────────────────────────

    /// @notice Completes a delivered deal once the review period has passed without a dispute.
    function claimAfterReview(uint256 dealId) external nonReentrant {
        Deal storage d = _deal(dealId);
        _requireStatus(d, Status.Delivered);
        if (block.timestamp <= d.deliveredAt + reviewPeriod) revert ReviewPeriodActive();
        _complete(dealId, d);
    }

    // ─────────────────────────────── Disputes ───────────────────────────────

    /// @notice Buyer or seller freezes the deal for arbitration.
    /// @dev The buyer may only dispute during the review period; afterwards the delivery counts as accepted.
    function openDispute(uint256 dealId) external {
        Deal storage d = _deal(dealId);
        if (msg.sender != d.buyer && msg.sender != d.seller) revert NotParticipant();
        if (d.status != Status.Funded && d.status != Status.Delivered) revert WrongStatus(d.status);
        if (d.status == Status.Delivered && block.timestamp > d.deliveredAt + reviewPeriod) {
            revert WrongStatus(d.status);
        }
        d.status = Status.Disputed;
        emit DisputeOpened(dealId, msg.sender);
    }

    /**
     * @notice Arbiter splits a disputed deal.
     * @param sellerShareBps Share of the escrow for the seller in basis points (0 = full refund, 10000 = seller gets all).
     *        The platform fee is charged only on the seller's part.
     */
    function resolveDispute(uint256 dealId, uint16 sellerShareBps) external onlyArbiter nonReentrant {
        if (sellerShareBps > BPS) revert InvalidShare();
        Deal storage d = _deal(dealId);
        _requireStatus(d, Status.Disputed);

        d.status = Status.Resolved;
        uint256 sellerGross = (d.amount * sellerShareBps) / BPS;
        uint256 toBuyer = d.amount - sellerGross;
        uint256 fee = (sellerGross * d.feeBps) / BPS;
        uint256 toSeller = sellerGross - fee;

        if (toSeller > 0) paymentToken.safeTransfer(d.seller, toSeller);
        if (toBuyer > 0) paymentToken.safeTransfer(d.buyer, toBuyer);
        if (fee > 0) paymentToken.safeTransfer(feeRecipient, fee);
        emit DisputeResolved(dealId, toSeller, toBuyer, fee);
    }

    // ─────────────────────────────── Admin ───────────────────────────────

    function setArbiter(address arbiter_) external onlyOwner {
        if (arbiter_ == address(0)) revert ZeroAddress();
        arbiter = arbiter_;
        emit ArbiterUpdated(arbiter_);
    }

    /// @notice Updates the fee for future deals. Existing deals keep their fee snapshot.
    function setFee(uint16 feeBps_, address feeRecipient_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
        emit FeeUpdated(feeBps_, feeRecipient_);
    }

    function setReviewPeriod(uint64 reviewPeriod_) external onlyOwner {
        reviewPeriod = reviewPeriod_;
        emit ReviewPeriodUpdated(reviewPeriod_);
    }

    // ────────────────────────────── Internal ─────────────────────────────

    function _deal(uint256 dealId) private view returns (Deal storage d) {
        d = deals[dealId];
        if (d.status == Status.None) revert WrongStatus(Status.None);
    }

    function _requireStatus(Deal storage d, Status expected) private view {
        if (d.status != expected) revert WrongStatus(d.status);
    }

    function _complete(uint256 dealId, Deal storage d) private {
        d.status = Status.Completed;
        uint256 fee = (d.amount * d.feeBps) / BPS;
        uint256 payout = d.amount - fee;
        paymentToken.safeTransfer(d.seller, payout);
        if (fee > 0) paymentToken.safeTransfer(feeRecipient, fee);
        emit DealCompleted(dealId, payout, fee);
    }

    function _refund(uint256 dealId, Deal storage d) private {
        d.status = Status.Refunded;
        paymentToken.safeTransfer(d.buyer, d.amount);
        emit DealRefunded(dealId, d.amount);
    }
}
