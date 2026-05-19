#!/usr/bin/env python3
"""
LEO Time-Scale Separation — Numerical Experiments
===================================================
Simulates the scaled stochastic system Z^{N,gamma} for the LEO debris
chemical reaction network from the paper.

Reactions:
  1. emptyset -> I          (launches,         rate kappa_1)
  2. 2I       -> 2F         (intact-intact,    rate kappa_2)
  3. I + F    -> 2F         (intact-fragment,  rate kappa_3)
  4. I        -> emptyset   (de-orbit,         rate kappa_4)
  5. F        -> emptyset   (fragment decay,   rate kappa_5)

Reference system N0 = 10000, X_I = 10000, X_F = 500000.
"""

import numpy as np
from scipy.integrate import solve_ivp
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from pathlib import Path
import os, time

# ============================================================
# Reference system
# ============================================================
N0 = 10_000
XI_REF = 10_000
XF_REF = 500_000

# Total reaction rates at reference (per year)
R = np.array([
    100.0,       # R1: launches
    3.0 / 20.0,  # R2: intact-intact collisions
    1.0 / 9.0,   # R3: intact-fragment collisions
    1.0 / 5.0,   # R4: de-orbiting
    1.0 / 30.0,  # R5: fragment decay
])

# Scaling exponents rho_k = log(R_k) / log(N0)
rho = np.log(R) / np.log(N0)

# Physical rate constants at N0
kappa_ref = np.array([
    R[0],                              # kappa_1 (no population dependence)
    R[1] / (XI_REF * (XI_REF - 1)),   # kappa_2
    R[2] / (XI_REF * XF_REF),         # kappa_3
    R[3] / XI_REF,                     # kappa_4
    R[4] / XF_REF,                     # kappa_5
])

# Input vectors nu_k
NU = np.array([
    [0, 0],  # reaction 1
    [2, 0],  # reaction 2
    [1, 1],  # reaction 3
    [1, 0],  # reaction 4
    [0, 1],  # reaction 5
])

# Net-change vectors zeta_k
ZETA = np.array([
    [+1,  0],  # reaction 1
    [-2, +2],  # reaction 2
    [-1, +1],  # reaction 3
    [-1,  0],  # reaction 4
    [ 0, -1],  # reaction 5
])


def derive_params(alpha_I, alpha_F):
    """Derive all scaling parameters for a given (alpha_I, alpha_F)."""
    alpha = np.array([alpha_I, alpha_F])

    # beta_k = rho_k - alpha . nu_k
    beta = rho - NU @ alpha

    # O(1) constants: c_k = kappa_k(N0) * N0^{beta_k}
    c = kappa_ref * N0 ** beta

    # Scaled initial conditions
    z_I0 = XI_REF / N0 ** alpha_I if alpha_I >= 0 else XI_REF * N0 ** (-alpha_I)
    z_F0 = XF_REF / N0 ** alpha_F if alpha_F >= 0 else XF_REF * N0 ** (-alpha_F)

    # Time-scale exponents
    gamma_I = alpha_I - rho[0]   # gamma_I = alpha_I - rho_1
    gamma_F = alpha_F - rho[4]   # gamma_F = alpha_F - rho_5

    return dict(alpha_I=alpha_I, alpha_F=alpha_F, alpha=alpha,
                beta=beta, c=c, z_I0=z_I0, z_F0=z_F0,
                gamma_I=gamma_I, gamma_F=gamma_F)


def rate_constants_at_N(par, N):
    """Rate constants kappa_k(N) = c_k * N^{-beta_k}."""
    return par["c"] * N ** (-par["beta"])


def initial_conditions_at_N(par, N):
    """Integer initial conditions at scale N."""
    XI0 = par["z_I0"] * N ** par["alpha_I"]
    XF0 = par["z_F0"] * N ** par["alpha_F"]
    return max(round(XI0), 0), max(round(XF0), 0)


# ============================================================
# ODE solver (deterministic fluid limit)
# ============================================================
def ode_rhs(t, state, kap):
    XI, XF = state
    XI = max(XI, 0.0)
    XF = max(XF, 0.0)
    k1, k2, k3, k4, k5 = kap

    dXI = k1 - 2*k2*XI*max(XI - 1, 0) - k3*XI*XF - k4*XI
    dXF = 2*k2*XI*max(XI - 1, 0) + k3*XI*XF - k5*XF
    return [dXI, dXF]


def simulate_ode(par, N, T_real, n_points=5000):
    """Solve the deterministic ODE at scale N for real time T_real."""
    kap = rate_constants_at_N(par, N)
    XI0, XF0 = initial_conditions_at_N(par, N)

    t_eval = np.linspace(0, T_real, n_points)
    sol = solve_ivp(
        lambda t, y: ode_rhs(t, y, kap),
        [0, T_real], [float(XI0), float(XF0)],
        t_eval=t_eval, method="LSODA",
        rtol=1e-10, atol=1e-12,
        max_step=T_real / 200,
    )
    return sol.t, sol.y[0], sol.y[1]


# ============================================================
# Gillespie SSA (stochastic simulation)
# ============================================================
def gillespie(par, N, T_real, max_events=int(5e6), thin=100):
    """
    Exact Gillespie simulation at scale N.
    Returns thinned trajectory (every `thin`-th event recorded).
    """
    kap = rate_constants_at_N(par, N)
    XI, XF = initial_conditions_at_N(par, N)

    times = [0.0]
    XI_hist = [float(XI)]
    XF_hist = [float(XF)]

    t = 0.0
    n_ev = 0

    while t < T_real and n_ev < max_events:
        # Propensities
        a = np.array([
            kap[0],                                    # launch
            kap[1] * XI * max(XI - 1, 0),              # I-I collision
            kap[2] * XI * XF,                          # I-F collision
            kap[3] * XI,                               # de-orbit
            kap[4] * XF,                               # F decay
        ], dtype=float)

        a_total = a.sum()
        if a_total <= 0:
            break

        dt = np.random.exponential(1.0 / a_total)
        t += dt
        if t > T_real:
            break

        # Choose reaction
        cum = np.cumsum(a)
        rxn = np.searchsorted(cum, np.random.random() * a_total)
        rxn = min(rxn, 4)

        XI += ZETA[rxn, 0]
        XF += ZETA[rxn, 1]
        XI = max(XI, 0)
        XF = max(XF, 0)
        n_ev += 1

        if n_ev % thin == 0:
            times.append(t)
            XI_hist.append(float(XI))
            XF_hist.append(float(XF))

    times.append(min(t, T_real))
    XI_hist.append(float(XI))
    XF_hist.append(float(XF))

    return np.array(times), np.array(XI_hist), np.array(XF_hist)


# ============================================================
# Tau-leaping (for large populations)
# ============================================================
def tau_leap(par, N, T_real, dt_leap=0.01, n_record=5000):
    """Approximate tau-leaping simulation for large populations."""
    kap = rate_constants_at_N(par, N)
    XI, XF = initial_conditions_at_N(par, N)
    XI, XF = float(XI), float(XF)

    record_interval = max(1, int(T_real / dt_leap / n_record))
    times = [0.0]
    XI_hist = [XI]
    XF_hist = [XF]

    t = 0.0
    step = 0
    while t < T_real:
        a = np.array([
            kap[0],
            kap[1] * XI * max(XI - 1, 0),
            kap[2] * XI * XF,
            kap[3] * XI,
            kap[4] * XF,
        ], dtype=float)
        a = np.maximum(a, 0.0)

        # Adaptive step size: ensure expected firings are not too large
        a_max = a.max()
        if a_max * dt_leap > 100:
            dt_use = 100.0 / max(a_max, 1e-30)
        else:
            dt_use = dt_leap
        dt_use = min(dt_use, T_real - t)

        # Poisson draws for each reaction
        firings = np.random.poisson(a * dt_use)

        for k in range(5):
            XI += ZETA[k, 0] * firings[k]
            XF += ZETA[k, 1] * firings[k]
        XI = max(XI, 0.0)
        XF = max(XF, 0.0)

        t += dt_use
        step += 1

        if step % record_interval == 0:
            times.append(t)
            XI_hist.append(XI)
            XF_hist.append(XF)

    times.append(t)
    XI_hist.append(XI)
    XF_hist.append(XF)

    return np.array(times), np.array(XI_hist), np.array(XF_hist)


# ============================================================
# Plotting helpers
# ============================================================
def to_scaled(t, XI, XF, par, N, gamma):
    """Convert physical trajectory to (tau, Z_I, Z_F) at time-scale gamma."""
    tau = N ** gamma * t
    ZI = N ** (-par["alpha_I"]) * XI
    ZF = N ** (-par["alpha_F"]) * XF
    return tau, ZI, ZF


def make_figure_dir():
    d = Path("figures")
    d.mkdir(exist_ok=True)
    return d


# ============================================================
# EXPERIMENT 1: alpha_I = 4, alpha_F = 6
# ============================================================
def run_experiment_1(figdir):
    print("\n" + "=" * 60)
    print("EXPERIMENT 1: alpha_I = 4, alpha_F = 6")
    print("=" * 60)

    par = derive_params(alpha_I=4, alpha_F=6)
    print(f"  rho   = {rho}")
    print(f"  beta  = {par['beta']}")
    print(f"  c     = {par['c']}")
    print(f"  z_I0  = {par['z_I0']:.4e},  z_F0 = {par['z_F0']:.4e}")
    print(f"  gamma_I = {par['gamma_I']:.4f}")
    print(f"  gamma_F = {par['gamma_F']:.4f}")

    # ---- Panel A: Physical system at N0 ----
    # Simulate the physical ODE for long enough to see interesting dynamics
    T_phys = 200_000  # 200k years
    print(f"\n  [ODE] Simulating physical system at N0={N0} for {T_phys} years...")
    t0 = time.time()
    t_ode, XI_ode, XF_ode = simulate_ode(par, N0, T_phys, n_points=8000)
    print(f"  [ODE] Done in {time.time()-t0:.1f}s")

    # ---- Panel B: Scaled trajectories at multiple N ----
    # For Exp 1, N0 is the only feasible scale (X grows as N^4, N^6)
    # Show Z at both time-scales
    gamma_I = par["gamma_I"]
    gamma_F = par["gamma_F"]

    tau_I, ZI_gI, ZF_gI = to_scaled(t_ode, XI_ode, XF_ode, par, N0, gamma_I)
    tau_F, ZI_gF, ZF_gF = to_scaled(t_ode, XI_ode, XF_ode, par, N0, gamma_F)

    # ---- Also do a few Gillespie runs at N0 for stochastic overlay ----
    n_gillespie = 3
    T_gill = 5000  # shorter for Gillespie
    gill_runs = []
    print(f"  [Gillespie] Running {n_gillespie} trajectories at N0 for {T_gill} years...")
    for i in range(n_gillespie):
        t0 = time.time()
        tg, XIg, XFg = gillespie(par, N0, T_gill, max_events=int(2e6), thin=50)
        gill_runs.append((tg, XIg, XFg))
        print(f"    run {i+1}: {len(tg)} points, {time.time()-t0:.1f}s")

    # ---- Multi-N convergence (ODE only) ----
    N_vals = [N0, int(2*N0), int(5*N0)]
    T_multi = 100_000
    multi_runs = {}
    print(f"  [Multi-N ODE] N = {N_vals}, T = {T_multi} years...")
    for N in N_vals:
        t0 = time.time()
        try:
            tv, XIv, XFv = simulate_ode(par, N, T_multi, n_points=5000)
            multi_runs[N] = (tv, XIv, XFv)
            print(f"    N={N}: done in {time.time()-t0:.1f}s")
        except Exception as e:
            print(f"    N={N}: FAILED ({e})")

    # ---- PLOT 1: Physical trajectories ----
    fig, axes = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    fig.suptitle(r"Experiment 1: $\alpha_I=4,\;\alpha_F=6$ — Physical System at $N_0=10^4$",
                 fontsize=14)

    ax = axes[0]
    ax.plot(t_ode / 1000, XI_ode, "b-", lw=1.5, label="ODE")
    for i, (tg, XIg, XFg) in enumerate(gill_runs):
        lbl = "Gillespie" if i == 0 else None
        ax.plot(tg / 1000, XIg, color="steelblue", alpha=0.4, lw=0.5, label=lbl)
    ax.set_ylabel(r"$X_I(t)$ (intacts)")
    ax.legend()
    ax.set_title("Intact count")

    ax = axes[1]
    ax.plot(t_ode / 1000, XF_ode, "r-", lw=1.5, label="ODE")
    for i, (tg, XIg, XFg) in enumerate(gill_runs):
        lbl = "Gillespie" if i == 0 else None
        ax.plot(tg / 1000, XFg, color="salmon", alpha=0.4, lw=0.5, label=lbl)
    ax.set_ylabel(r"$X_F(t)$ (fragments)")
    ax.set_xlabel("Time (thousand years)")
    ax.legend()
    ax.set_title("Fragment count")

    plt.tight_layout()
    fig.savefig(figdir / "exp1_physical.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved exp1_physical.png")

    # ---- PLOT 2: Scaled trajectories Z at gamma_I ----
    fig, axes = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    fig.suptitle(
        r"Experiment 1: Scaled system at $\gamma_I = %.2f$" % gamma_I
        + r" (intact time-scale)", fontsize=14)

    ax = axes[0]
    ax.plot(tau_I, ZI_gI, "b-", lw=1.5)
    ax.set_ylabel(r"$Z_I^{N,\gamma_I}$")
    ax.set_title(r"$Z_I$ vs $\tau = N_0^{\gamma_I}\,t$")
    ax.ticklabel_format(style="scientific", axis="both", scilimits=(-2, 4))

    ax = axes[1]
    ax.plot(tau_I, ZF_gI, "r-", lw=1.5)
    ax.set_ylabel(r"$Z_F^{N,\gamma_I}$")
    ax.set_xlabel(r"$\tau = N_0^{\gamma_I}\,t$")
    ax.set_title(r"$Z_F$ vs $\tau = N_0^{\gamma_I}\,t$")
    ax.ticklabel_format(style="scientific", axis="both", scilimits=(-2, 4))

    plt.tight_layout()
    fig.savefig(figdir / "exp1_scaled_gammaI.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved exp1_scaled_gammaI.png")

    # ---- PLOT 3: Scaled trajectories Z at gamma_F ----
    fig, axes = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    fig.suptitle(
        r"Experiment 1: Scaled system at $\gamma_F = %.2f$" % gamma_F
        + r" (fragment time-scale)", fontsize=14)

    ax = axes[0]
    ax.plot(tau_F, ZI_gF, "b-", lw=1.5)
    ax.set_ylabel(r"$Z_I^{N,\gamma_F}$")
    ax.set_title(r"$Z_I$ vs $\tau = N_0^{\gamma_F}\,t$")
    ax.ticklabel_format(style="scientific", axis="both", scilimits=(-2, 4))

    ax = axes[1]
    ax.plot(tau_F, ZF_gF, "r-", lw=1.5)
    ax.set_ylabel(r"$Z_F^{N,\gamma_F}$")
    ax.set_xlabel(r"$\tau = N_0^{\gamma_F}\,t$")
    ax.set_title(r"$Z_F$ vs $\tau = N_0^{\gamma_F}\,t$")
    ax.ticklabel_format(style="scientific", axis="both", scilimits=(-2, 4))

    plt.tight_layout()
    fig.savefig(figdir / "exp1_scaled_gammaF.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved exp1_scaled_gammaF.png")

    # ---- PLOT 4: Multi-N convergence ----
    if len(multi_runs) > 1:
        fig, axes = plt.subplots(2, 2, figsize=(14, 10))
        fig.suptitle(
            r"Experiment 1: Convergence across $N$ values", fontsize=14)

        colors = plt.cm.viridis(np.linspace(0.2, 0.8, len(multi_runs)))

        for idx, (N, (tv, XIv, XFv)) in enumerate(sorted(multi_runs.items())):
            tau_i, zi_i, zf_i = to_scaled(tv, XIv, XFv, par, N, gamma_I)
            tau_f, zi_f, zf_f = to_scaled(tv, XIv, XFv, par, N, gamma_F)

            axes[0, 0].plot(tau_i, zi_i, color=colors[idx], lw=1.2,
                            label=f"N={N}")
            axes[0, 1].plot(tau_i, zf_i, color=colors[idx], lw=1.2,
                            label=f"N={N}")
            axes[1, 0].plot(tau_f, zi_f, color=colors[idx], lw=1.2,
                            label=f"N={N}")
            axes[1, 1].plot(tau_f, zf_f, color=colors[idx], lw=1.2,
                            label=f"N={N}")

        axes[0, 0].set_title(r"$Z_I$ at $\gamma_I$")
        axes[0, 1].set_title(r"$Z_F$ at $\gamma_I$")
        axes[1, 0].set_title(r"$Z_I$ at $\gamma_F$")
        axes[1, 1].set_title(r"$Z_F$ at $\gamma_F$")
        for ax in axes.flat:
            ax.legend(fontsize=8)
            ax.ticklabel_format(style="scientific", scilimits=(-2, 4))

        plt.tight_layout()
        fig.savefig(figdir / "exp1_convergence.png", dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"  Saved exp1_convergence.png")


# ============================================================
# EXPERIMENT 2: alpha_I = 0, alpha_F = 3/2
# ============================================================
def run_experiment_2(figdir):
    print("\n" + "=" * 60)
    print("EXPERIMENT 2: alpha_I = 0, alpha_F = 3/2")
    print("=" * 60)

    par = derive_params(alpha_I=0, alpha_F=1.5)
    print(f"  rho   = {rho}")
    print(f"  beta  = {par['beta']}")
    print(f"  c     = {par['c']}")
    print(f"  z_I0  = {par['z_I0']:.4e},  z_F0 = {par['z_F0']:.4e}")
    print(f"  gamma_I = {par['gamma_I']:.4f}")
    print(f"  gamma_F = {par['gamma_F']:.4f}")

    gamma_I = par["gamma_I"]
    gamma_F = par["gamma_F"]

    # ---- Physical system at N0 ----
    T_phys = 500_000  # 500k years
    print(f"\n  [ODE] Simulating physical system at N0={N0} for {T_phys} years...")
    t0 = time.time()
    t_ode, XI_ode, XF_ode = simulate_ode(par, N0, T_phys, n_points=10000)
    print(f"  [ODE] Done in {time.time()-t0:.1f}s")

    # ---- Gillespie at N0 (short run) ----
    n_gillespie = 3
    T_gill = 3000
    gill_runs = []
    print(f"  [Gillespie] Running {n_gillespie} trajectories at N0 for {T_gill} years...")
    for i in range(n_gillespie):
        t0 = time.time()
        tg, XIg, XFg = gillespie(par, N0, T_gill, max_events=int(2e6), thin=50)
        gill_runs.append((tg, XIg, XFg))
        print(f"    run {i+1}: {len(tg)} points, {time.time()-t0:.1f}s")

    # ---- Multi-N convergence ----
    N_vals = [1000, 5000, N0, 50000]
    T_multi = 200_000
    multi_runs = {}
    print(f"  [Multi-N ODE] N = {N_vals}, T = {T_multi} years...")
    for N in N_vals:
        t0 = time.time()
        try:
            tv, XIv, XFv = simulate_ode(par, N, T_multi, n_points=5000)
            multi_runs[N] = (tv, XIv, XFv)
            print(f"    N={N}: done in {time.time()-t0:.1f}s")
        except Exception as e:
            print(f"    N={N}: FAILED ({e})")

    # ---- Scaled trajectories ----
    tau_I, ZI_gI, ZF_gI = to_scaled(t_ode, XI_ode, XF_ode, par, N0, gamma_I)
    tau_F, ZI_gF, ZF_gF = to_scaled(t_ode, XI_ode, XF_ode, par, N0, gamma_F)

    # ---- PLOT 1: Physical trajectories ----
    fig, axes = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    fig.suptitle(
        r"Experiment 2: $\alpha_I=0,\;\alpha_F=\frac{3}{2}$"
        r" — Physical System at $N_0=10^4$", fontsize=14)

    ax = axes[0]
    ax.plot(t_ode / 1000, XI_ode, "b-", lw=1.5, label="ODE")
    for i, (tg, XIg, XFg) in enumerate(gill_runs):
        lbl = "Gillespie" if i == 0 else None
        ax.plot(tg / 1000, XIg, color="steelblue", alpha=0.4, lw=0.5, label=lbl)
    ax.set_ylabel(r"$X_I(t)$ (intacts)")
    ax.legend()
    ax.set_title("Intact count")

    ax = axes[1]
    ax.plot(t_ode / 1000, XF_ode, "r-", lw=1.5, label="ODE")
    for i, (tg, XIg, XFg) in enumerate(gill_runs):
        lbl = "Gillespie" if i == 0 else None
        ax.plot(tg / 1000, XFg, color="salmon", alpha=0.4, lw=0.5, label=lbl)
    ax.set_ylabel(r"$X_F(t)$ (fragments)")
    ax.set_xlabel("Time (thousand years)")
    ax.legend()
    ax.set_title("Fragment count")

    plt.tight_layout()
    fig.savefig(figdir / "exp2_physical.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved exp2_physical.png")

    # ---- PLOT 2: Scaled Z at gamma_I (intact time-scale) ----
    fig, axes = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    fig.suptitle(
        r"Experiment 2: Scaled system at $\gamma_I = %.2f$" % gamma_I
        + r" (intact time-scale, NOTE: $\gamma_I < 0$)", fontsize=14)

    ax = axes[0]
    ax.plot(tau_I, ZI_gI, "b-", lw=1.5)
    ax.set_ylabel(r"$Z_I^{N,\gamma_I} = X_I$")
    ax.set_title(r"$Z_I$ vs $\tau = N_0^{\gamma_I}\,t$ "
                 r"(since $\alpha_I=0$, $Z_I = X_I$)")

    ax = axes[1]
    ax.plot(tau_I, ZF_gI, "r-", lw=1.5)
    ax.set_ylabel(r"$Z_F^{N,\gamma_I}$")
    ax.set_xlabel(r"$\tau = N_0^{\gamma_I}\,t$")
    ax.set_title(r"$Z_F$ vs $\tau = N_0^{\gamma_I}\,t$")

    plt.tight_layout()
    fig.savefig(figdir / "exp2_scaled_gammaI.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved exp2_scaled_gammaI.png")

    # ---- PLOT 3: Scaled Z at gamma_F (fragment time-scale) ----
    fig, axes = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    fig.suptitle(
        r"Experiment 2: Scaled system at $\gamma_F = %.2f$" % gamma_F
        + r" (fragment time-scale)", fontsize=14)

    ax = axes[0]
    ax.plot(tau_F, ZI_gF, "b-", lw=1.5)
    ax.set_ylabel(r"$Z_I^{N,\gamma_F}$")
    ax.set_title(r"$Z_I$ vs $\tau = N_0^{\gamma_F}\,t$")
    ax.ticklabel_format(style="scientific", scilimits=(-2, 4))

    ax = axes[1]
    ax.plot(tau_F, ZF_gF, "r-", lw=1.5)
    ax.set_ylabel(r"$Z_F^{N,\gamma_F}$")
    ax.set_xlabel(r"$\tau = N_0^{\gamma_F}\,t$")
    ax.set_title(r"$Z_F$ vs $\tau = N_0^{\gamma_F}\,t$")
    ax.ticklabel_format(style="scientific", scilimits=(-2, 4))

    plt.tight_layout()
    fig.savefig(figdir / "exp2_scaled_gammaF.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved exp2_scaled_gammaF.png")

    # ---- PLOT 4: Multi-N convergence ----
    if len(multi_runs) > 1:
        fig, axes = plt.subplots(2, 2, figsize=(14, 10))
        fig.suptitle(
            r"Experiment 2: Convergence across $N$ values "
            r"($\alpha_I=0, \alpha_F=3/2$)", fontsize=14)

        colors = plt.cm.viridis(np.linspace(0.15, 0.85, len(multi_runs)))

        for idx, (N, (tv, XIv, XFv)) in enumerate(sorted(multi_runs.items())):
            tau_i, zi_i, zf_i = to_scaled(tv, XIv, XFv, par, N, gamma_I)
            tau_f, zi_f, zf_f = to_scaled(tv, XIv, XFv, par, N, gamma_F)

            axes[0, 0].plot(tau_i, zi_i, color=colors[idx], lw=1.2,
                            label=f"N={N}")
            axes[0, 1].plot(tau_i, zf_i, color=colors[idx], lw=1.2,
                            label=f"N={N}")
            axes[1, 0].plot(tau_f, zi_f, color=colors[idx], lw=1.2,
                            label=f"N={N}")
            axes[1, 1].plot(tau_f, zf_f, color=colors[idx], lw=1.2,
                            label=f"N={N}")

        axes[0, 0].set_title(r"$Z_I$ at $\gamma_I$")
        axes[0, 0].set_ylabel(r"$Z_I = X_I$")
        axes[0, 1].set_title(r"$Z_F$ at $\gamma_I$")
        axes[1, 0].set_title(r"$Z_I$ at $\gamma_F$")
        axes[1, 0].set_ylabel(r"$Z_I$")
        axes[1, 1].set_title(r"$Z_F$ at $\gamma_F$")
        for ax in axes.flat:
            ax.legend(fontsize=8)
            ax.ticklabel_format(style="scientific", scilimits=(-2, 4))
        axes[1, 0].set_xlabel(r"$\tau$")
        axes[1, 1].set_xlabel(r"$\tau$")

        plt.tight_layout()
        fig.savefig(figdir / "exp2_convergence.png", dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"  Saved exp2_convergence.png")

    # ---- PLOT 5: Kessler threshold analysis ----
    XI_crit = kappa_ref[4] / kappa_ref[2]
    print(f"\n  Kessler critical intact count: X_I_crit = kappa_5/kappa_3 = {XI_crit:.0f}")

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.plot(t_ode / 1000, XI_ode, "b-", lw=1.5, label=r"$X_I(t)$")
    ax.axhline(XI_crit, color="k", ls="--", lw=1, label=r"$X_I^{\rm crit} = \kappa_5/\kappa_3$")
    ax.set_xlabel("Time (thousand years)")
    ax.set_ylabel("Intact count")
    ax.set_title(
        r"Kessler Threshold: $X_I^{\rm crit} = %.0f$" % XI_crit
        + r" — fragments grow when $X_I > X_I^{\rm crit}$")
    ax.legend()
    plt.tight_layout()
    fig.savefig(figdir / "exp2_kessler.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved exp2_kessler.png")


# ============================================================
# Summary table
# ============================================================
def print_summary():
    print("\n" + "=" * 60)
    print("PARAMETER SUMMARY")
    print("=" * 60)
    print(f"  N0 = {N0}")
    print(f"  X_I(0) = {XI_REF},  X_F(0) = {XF_REF}")
    print()
    labels = ["Launch", "I-I coll", "I-F coll", "De-orbit", "F decay"]
    print(f"  {'Reaction':<12} {'N0^rho':>10} {'rho':>10} {'kappa':>14}")
    print(f"  {'-'*12} {'-'*10} {'-'*10} {'-'*14}")
    for i in range(5):
        print(f"  {labels[i]:<12} {R[i]:>10.4f} {rho[i]:>10.4f} {kappa_ref[i]:>14.4e}")
    print()

    for name, aI, aF in [("Exp 1", 4, 6), ("Exp 2", 0, 1.5)]:
        p = derive_params(aI, aF)
        print(f"  {name} (alpha_I={aI}, alpha_F={aF}):")
        print(f"    gamma_I = {p['gamma_I']:.4f}")
        print(f"    gamma_F = {p['gamma_F']:.4f}")
        print(f"    z_I0 = {p['z_I0']:.4e},  z_F0 = {p['z_F0']:.4e}")
        print(f"    beta = {p['beta']}")
        print()


# ============================================================
# Main
# ============================================================
if __name__ == "__main__":
    np.random.seed(42)

    figdir = make_figure_dir()
    print_summary()
    run_experiment_1(figdir)
    run_experiment_2(figdir)

    print("\n" + "=" * 60)
    print("ALL DONE. Figures saved in ./figures/")
    print("=" * 60)
