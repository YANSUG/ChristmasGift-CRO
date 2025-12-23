// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // 更新版本號以匹配 OpenZeppelin v5

/**
 * @title The Christmas Gift (聖誕禮物)
 * @notice 20 CRO 入場 | MasterChef 分紅 | 聖誕節 (UTC-12) 強制結算
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract ChristmasGift is ReentrancyGuard, Ownable {
    using Address for address payable;

    // --- 1. 遊戲核心參數 ---
    uint256 public constant WISH_COST = 20 ether; // 20 CRO
    uint256 public constant WARMUP_THRESHOLD = 100; // 100 願望後啟動倒數
    uint256 public constant PERSONAL_COOLDOWN = 35 seconds; 
    uint256 private constant ACC_PRECISION = 1e12; // 分紅精度

    // --- 2. 聖誕協議觸發時間 ---
    // Timestamp: 1766750400 (對應 2025-12-26 12:00:00 UTC)
    uint256 public constant CHRISTMAS_END_TIMESTAMP = 1766750400; 

    // --- 3. 錢包地址 (已修正 Checksum) ---
    address payable public teamWallet;
    address payable public blackholeWallet;
    
    // --- 4. 遊戲變數 ---
    uint256 public roundId;
    uint256 public grandPot; // 獎池
    
    struct Round {
        bool isActive;          
        bool ended;             
        bool christmasEnded;    // 是否由聖誕協議結束
        uint256 endTimestamp;   
        uint256 totalWishes;    
        address winner;         
        uint256 accDividendPerShare; 
        uint256 christmasPerShare;   
    }

    struct Wisher {
        uint256 lastWishTime;     
        uint256 wishCount;        
        uint256 rewardDebt;       
        uint256 pendingDividends; 
        bool christmasClaimed;    
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => Wisher)) public wishers;

    // --- 事件 ---
    event NewWish(uint256 indexed roundId, address indexed player, uint256 wishCount, uint256 timeLeft);
    event RoundEnded(uint256 indexed roundId, address winner, uint256 potWon);
    event ChristmasProtocolTriggered(uint256 indexed roundId, uint256 totalDistribute, uint256 perShare);
    event DividendWithdrawn(address indexed player, uint256 amount);
    event ChristmasGiftClaimed(address indexed player, uint256 amount);

    // 建構函數：修正 Ownable 初始化與地址格式
    constructor() Ownable(msg.sender) {
        teamWallet = payable(0xCFf6cF868BB860c9CdeaC97E1099ff930bbBd441);
        // 下面這個地址已修正為 Checksum 格式 (大小寫混合)
        blackholeWallet = payable(0xBF3e09e13182507640232a605274B60fC46c39Bb);
        _startNewRound(0); 
    }

    // ============================================================
    // 核心互動：許願 (Wish)
    // ============================================================
    function wish() external payable nonReentrant {
        require(tx.origin == msg.sender, "No contracts allowed");
        require(msg.value == WISH_COST, "Cost must be exactly 20 CRO");

        Round storage rng = rounds[roundId];

        // 檢查超時結算
        if (rng.isActive && rng.totalWishes >= WARMUP_THRESHOLD && block.timestamp > rng.endTimestamp) {
            _endRound(rng.winner); 
            rng = rounds[roundId]; // 載入新局
        }
        
        require(!rng.ended && !rng.christmasEnded, "Round ended, wait for restart");

        Wisher storage user = wishers[roundId][msg.sender];
        require(block.timestamp >= user.lastWishTime + PERSONAL_COOLDOWN, "Cooldown active");

        // --- 資金分配 ---
        // 5% 團隊
        uint256 teamCut = (msg.value * 5) / 100;
        teamWallet.sendValue(teamCut);

        // 5% 黑洞
        uint256 blackholeCut = (msg.value * 5) / 100;
        blackholeWallet.sendValue(blackholeCut);

        // 10% 即時分紅
        uint256 dividendCut = (msg.value * 10) / 100;

        // 80% 獎池
        uint256 potAdd = msg.value - teamCut - blackholeCut - dividendCut;

        // --- MasterChef 分紅計算 ---
        if (user.wishCount > 0) {
            uint256 pending = (user.wishCount * rng.accDividendPerShare / ACC_PRECISION) - user.rewardDebt;
            user.pendingDividends += pending;
        }

        if (rng.totalWishes > 0) {
            rng.accDividendPerShare += (dividendCut * ACC_PRECISION) / rng.totalWishes;
        } else {
            potAdd += dividendCut; 
        }

        grandPot += potAdd;

        // --- 更新用戶狀態 ---
        user.wishCount++;
        user.lastWishTime = block.timestamp;
        user.rewardDebt = user.wishCount * rng.accDividendPerShare / ACC_PRECISION;

        // --- 更新遊戲進度 ---
        rng.totalWishes++;
        rng.winner = msg.sender;
        _updateTimer(rng);

        emit NewWish(roundId, msg.sender, rng.totalWishes, rng.isActive ? rng.endTimestamp - block.timestamp : 0);
    }

    // ============================================================
    // 遊戲邏輯
    // ============================================================
    function _updateTimer(Round storage rng) internal {
        if (rng.totalWishes < WARMUP_THRESHOLD) {
            return; 
        } else if (rng.totalWishes == WARMUP_THRESHOLD) {
            rng.endTimestamp = block.timestamp + 300 seconds;
            rng.isActive = true;
        } else {
            uint256 timeCap;
            if (rng.totalWishes <= 1000) timeCap = 300 seconds;
            else if (rng.totalWishes <= 10000) timeCap = 180 seconds;
            else if (rng.totalWishes <= 100000) timeCap = 120 seconds;
            else timeCap = 60 seconds;
            rng.endTimestamp = block.timestamp + timeCap;
        }
    }

    function _endRound(address _winner) internal {
        Round storage rng = rounds[roundId];
        rng.isActive = false;
        rng.ended = true;

        uint256 winAmount = (grandPot * 80) / 100;
        uint256 rollover = grandPot - winAmount;

        if (_winner != address(0)) {
            payable(_winner).sendValue(winAmount);
        } else {
            rollover = grandPot;
        }

        emit RoundEnded(roundId, _winner, winAmount);
        _startNewRound(rollover);
    }

    function _startNewRound(uint256 _seedMoney) internal {
        roundId++;
        grandPot = _seedMoney;
        rounds[roundId].isActive = false;
        rounds[roundId].accDividendPerShare = 0;
    }

    // --- 聖誕協議 (Post-Christmas Protocol) ---
    function triggerChristmasProtocol() external nonReentrant {
        require(block.timestamp >= CHRISTMAS_END_TIMESTAMP, "Christmas is not over yet (UTC-12)");
        
        Round storage rng = rounds[roundId];
        require(!rng.ended && !rng.christmasEnded, "Round already ended");
        require(rng.totalWishes > 0, "No wishes to distribute");

        rng.isActive = false;
        rng.christmasEnded = true;

        uint256 distributeAmount = grandPot / 2; // 50%
        uint256 rollover = grandPot - distributeAmount;

        // 計算快照 (Snapshot)
        rng.christmasPerShare = (distributeAmount * ACC_PRECISION) / rng.totalWishes;

        emit ChristmasProtocolTriggered(roundId, distributeAmount, rng.christmasPerShare);
        
        _startNewRound(rollover);
    }

    // 聖誕禮物領取
    function claimChristmasGift(uint256 _rId) external nonReentrant {
        Round storage rng = rounds[_rId];
        Wisher storage user = wishers[_rId][msg.sender];

        require(rng.christmasEnded, "Protocol not triggered");
        require(!user.christmasClaimed, "Already claimed");
        require(user.wishCount > 0, "No participation");

        uint256 giftAmount = (user.wishCount * rng.christmasPerShare) / ACC_PRECISION;
        user.christmasClaimed = true;
        
        payable(msg.sender).sendValue(giftAmount);
        emit ChristmasGiftClaimed(msg.sender, giftAmount);
    }

    // ============================================================
    // 玩家提款 (Withdraw)
    // ============================================================
    function withdrawDividends(uint256 _rId) external nonReentrant {
        Round storage rng = rounds[_rId];
        Wisher storage user = wishers[_rId][msg.sender];
        
        uint256 pending = (user.wishCount * rng.accDividendPerShare / ACC_PRECISION) - user.rewardDebt;
        uint256 total = user.pendingDividends + pending;
        
        user.pendingDividends = 0;
        user.rewardDebt = user.wishCount * rng.accDividendPerShare / ACC_PRECISION;

        require(total > 0, "No dividends");
        payable(msg.sender).sendValue(total);
        emit DividendWithdrawn(msg.sender, total);
    }

    // ============================================================
    // 前端查詢 (View Functions)
    // ============================================================
    function getPendingDividends(uint256 _rId, address _user) external view returns (uint256) {
        Round storage rng = rounds[_rId];
        Wisher storage user = wishers[_rId][_user];
        uint256 pending = (user.wishCount * rng.accDividendPerShare / ACC_PRECISION) - user.rewardDebt;
        return user.pendingDividends + pending;
    }

    function getPendingChristmasGift(uint256 _rId, address _user) external view returns (uint256) {
        Round storage rng = rounds[_rId];
        Wisher storage user = wishers[_rId][_user];
        if (!rng.christmasEnded || user.christmasClaimed) return 0;
        return (user.wishCount * rng.christmasPerShare) / ACC_PRECISION;
    }
    
    // 接收額外資金
    receive() external payable {
        grandPot += msg.value;
    }
}