// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract VestingVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    address public constant TEAM_ADDR =
        0x9958A0E8f79f911d12fCa5A6b3EB6E55391311DB;
    address public constant MKT_ADDR =
        0xFAFC9818C38df003A007aafE3A4E67618eAc23c1;

    uint32 private constant MONTH = 30 days;

    enum Role {
        NONE,
        TEAM,
        MARKETING
    }

    struct Schedule {
        uint128 total;
        uint128 released;
        uint64 start;
        uint64 cliff;
        uint64 duration;
        bool revocable;
        bool revoked;
    }

    mapping(address => Schedule) public schedules;
    mapping(address => Role) public roleOf;
    address[] public beneficiaries;

    event ScheduleCreated(
        address indexed beneficiary,
        uint256 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable,
        Role role
    );
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(
        address indexed beneficiary,
        uint256 unvestedReturned
    );
    event ScheduleIncreased(address indexed beneficiary, uint256 addAmount);

    constructor(address token_, address initialOwner) Ownable(initialOwner) {
        require(token_ != address(0), "TOKEN=0");
        token = IERC20(token_);
    }

    function createSchedule(
        address beneficiary,
        uint256 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable,
        Role role
    ) public onlyOwner {
        require(beneficiary != address(0), "BENEFICIARY=0");
        require(total > 0, "TOTAL=0");
        require(duration > 0, "DURATION=0");
        require(role != Role.NONE, "ROLE=NONE");
        require(schedules[beneficiary].total == 0, "EXISTS");

        schedules[beneficiary] = Schedule({
            total: uint128(total),
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revocable: revocable,
            revoked: false
        });
        roleOf[beneficiary] = role;
        beneficiaries.push(beneficiary);

        emit ScheduleCreated(
            beneficiary,
            total,
            start,
            cliff,
            duration,
            revocable,
            role
        );
    }

    function increaseSchedule(
        address beneficiary,
        uint256 addAmount
    ) external onlyOwner {
        require(addAmount > 0, "ADD=0");
        Schedule storage s = schedules[beneficiary];
        require(s.total > 0 && !s.revoked, "NO_SCHEDULE");
        s.total = uint128(uint256(s.total) + addAmount);
        emit ScheduleIncreased(beneficiary, addAmount);
    }

    function getBeneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }
    function getBeneficiaryAt(uint256 i) external view returns (address) {
        return beneficiaries[i];
    }

    function scheduleOf(
        address beneficiary
    )
        external
        view
        returns (
            uint128 total,
            uint128 released,
            uint64 start,
            uint64 cliff,
            uint64 duration,
            bool revocable,
            bool revoked
        )
    {
        Schedule memory s = schedules[beneficiary];
        return (
            s.total,
            s.released,
            s.start,
            s.cliff,
            s.duration,
            s.revocable,
            s.revoked
        );
    }

    function claimable(address beneficiary) public view returns (uint256) {
        Schedule memory s = schedules[beneficiary];
        if (s.total == 0 || s.revoked) return 0;

        uint64 t = uint64(block.timestamp);
        if (t < s.cliff) return 0;

        uint256 vested;
        if (t >= s.cliff + s.duration) {
            vested = s.total;
        } else {
            uint256 elapsed = t - s.cliff;
            vested = (uint256(s.total) * elapsed) / s.duration;
        }
        if (vested <= s.released) return 0;
        return vested - s.released;
    }

    function release(address beneficiary) public nonReentrant {
        uint256 amount = claimable(beneficiary);
        require(amount > 0, "NOTHING_TO_RELEASE");
        Schedule storage s = schedules[beneficiary];
        s.released = uint128(uint256(s.released) + amount);
        token.safeTransfer(beneficiary, amount);
        emit TokensReleased(beneficiary, amount);
    }

    function releaseFor(address beneficiary) external {
        release(beneficiary);
    }

    function revoke(address beneficiary) external onlyOwner nonReentrant {
        Schedule storage s = schedules[beneficiary];
        require(s.total > 0 && !s.revoked, "NO_SCHEDULE");
        require(s.revocable, "NOT_REVOCABLE");

        uint256 vested = s.released + claimable(beneficiary);
        uint256 unvested = 0;
        if (vested < s.total) unvested = s.total - vested;

        s.revoked = true;
        if (unvested > 0) token.safeTransfer(owner(), unvested);
        emit ScheduleRevoked(beneficiary, unvested);
    }

    function setupTeamSevenMonthlyTranches(
        uint256 firstMonth2Amount,
        uint64 TGE,
        address beneficiary
    ) external onlyOwner {
        address who = beneficiary == address(0) ? TEAM_ADDR : beneficiary;
        require(schedules[who].total == 0, "TEAM_EXISTS");

        uint64 start2 = TGE + 1 * MONTH;
        _create(who, firstMonth2Amount, TGE, start2, MONTH, false, Role.TEAM);

        for (uint256 m = 2; m <= 7; m++) {
            uint64 startM = TGE + uint64(m) * MONTH;
            _create(
                who,
                firstMonth2Amount,
                TGE,
                startM,
                MONTH,
                false,
                Role.TEAM
            );
        }
    }

    function setupMarketingStream(
        uint256 total,
        uint64 startCliff,
        uint64 durationSeconds,
        address beneficiary
    ) external onlyOwner {
        address who = beneficiary == address(0) ? MKT_ADDR : beneficiary;
        require(schedules[who].total == 0, "MKT_EXISTS");
        require(durationSeconds > 0, "DUR=0");
        _create(
            who,
            total,
            startCliff,
            startCliff,
            durationSeconds,
            false,
            Role.MARKETING
        );
    }

    function _create(
        address beneficiary,
        uint256 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable,
        Role role
    ) internal {
        Schedule storage s = schedules[beneficiary];
        if (s.total == 0) {
            schedules[beneficiary] = Schedule({
                total: uint128(total),
                released: 0,
                start: start,
                cliff: cliff,
                duration: duration,
                revocable: revocable,
                revoked: false
            });
            roleOf[beneficiary] = role;
            beneficiaries.push(beneficiary);
            emit ScheduleCreated(
                beneficiary,
                total,
                start,
                cliff,
                duration,
                revocable,
                role
            );
        } else {
            require(roleOf[beneficiary] == role, "ROLE_MISMATCH");
            require(!s.revoked, "REVOKED");

            if (
                s.start == start &&
                s.cliff == cliff &&
                s.duration == duration &&
                s.revocable == revocable
            ) {
                s.total = uint128(uint256(s.total) + total);
                emit ScheduleIncreased(beneficiary, total);
            } else {
                uint64 newCliff = cliff > s.cliff ? cliff : s.cliff;
                uint64 endA = s.cliff + s.duration;
                uint64 endB = cliff + duration;
                uint64 newEnd = endB > endA ? endB : endA;
                s.cliff = newCliff;
                s.duration = newEnd - newCliff;
                s.total = uint128(uint256(s.total) + total);
                if (revocable && !s.revocable) s.revocable = true;
                emit ScheduleIncreased(beneficiary, total);
            }
        }
    }
}
