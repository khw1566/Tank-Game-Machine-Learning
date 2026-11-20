"""PPO probabilities for the V6 unlocked-camera controls applied by TankAgent."""
import torch
from stable_baselines3.common.distributions import DiagGaussianDistribution
from stable_baselines3.common.policies import ActorCriticPolicy


class V6ControlDistribution(DiagGaussianDistribution):
    """Sample the same Gaussian and score the mass of its resulting command."""

    def command_log_probs(self, actions):
        # Godot roundi rounds half away from zero. A bin at either limit also
        # receives the entire tail outside the Box clipped by SB3.
        clipped = actions.detach().clamp(-1, 1)
        code = clipped.sign() * (clipped.abs() * 127 + 0.5).floor()
        first, last = code.clone(), code.clone()
        brake_off = code[:, 2] <= 0
        first[:, 2] = torch.where(brake_off, -127, code[:, 2])
        last[:, 2] = torch.where(brake_off, 0, code[:, 2])
        for axis in (5, 7):  # fire and free-look
            pressed = code[:, axis] > 0
            first[:, axis] = torch.where(pressed, 1, -127)
            last[:, axis] = torch.where(pressed, 127, 0)
        view = code[:, 6]
        third, commander = view < -42, view > 42
        gunner = ~(third | commander)
        first[:, 6] = torch.where(third, -127, torch.where(commander, 43, -42))
        last[:, 6] = torch.where(third, -43, torch.where(commander, 127, 42))

        # TankView's gunner zoom selects low/high or keeps the previous setting.
        zoom = code[:, 10]
        first[:, 10] = torch.where(gunner, torch.where(zoom < -63, -127, torch.where(zoom > 63, 64, -63)), first[:, 10])
        last[:, 10] = torch.where(gunner, torch.where(zoom < -63, -64, torch.where(zoom > 63, 127, 63)), last[:, 10])

        mean, std = self.distribution.mean, self.distribution.stddev
        low = ((first - 0.5) / 127 - mean) / std
        high = ((last + 0.5) / 127 - mean) / std
        left_tail, right_tail = first == -127, last == 127
        # Evaluate right-side intervals via the survival function. log-CDF
        # differences otherwise round down to zero for infrequent actions.
        flip = right_tail | (~left_tail & (low + high > 0))
        near = torch.special.log_ndtr(torch.where(flip, -low, high))
        far = torch.special.log_ndtr(torch.where(flip, -high, low))
        mass = (-torch.expm1(far - near)).clamp_min(torch.finfo(mean.dtype).tiny)
        log_probs = near + torch.where(left_tail | right_tail, 0.0, mass.log())
        # The sampled view and free-look command determine which axes the game
        # consumes. Integrating over an unused input gives probability one.
        look = commander | (third & (code[:, 7] > 0))
        active = torch.ones_like(code, dtype=torch.bool)
        active[:, 3:5] = ~look[:, None]
        active[:, 7] = third
        active[:, 8:10] = look[:, None]
        active[:, 10] = ~third
        return torch.where(active, log_probs, 0.0)

    def log_prob(self, actions):
        return self.command_log_probs(actions).sum(dim=1)

    def entropy(self):
        # The selected camera changes the entropy of the remaining controls.
        # Score the joint command so those conditional terms also train view
        # selection. Other independent action draws form a leave-one-out baseline.
        lp = self.log_prob(self.distribution.sample())
        sample = lp.detach()
        baseline = (sample.sum() - sample) / (sample.numel() - 1) if sample.numel() > 1 else 0.0
        return -lp - (sample - baseline) * (lp - sample)


class V6ControlPolicy(ActorCriticPolicy):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Existing gSDE checkpoints rely on their state-dependent covariance.
        if isinstance(self.action_dist, DiagGaussianDistribution) and self.action_space.shape == (11,):
            self.action_dist = V6ControlDistribution(11)
