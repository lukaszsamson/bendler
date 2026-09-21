import Base

# Independent damped oscillators in a harmonic potential. The balanced tree
# exposes pure parallel work; only the sequential IO spine emits snapshots.
type Cloud is Data:
  Body{x: F32, y: F32, vx: F32, vy: F32}
  Fork{left: Cloud, right: Cloud}

def integrate(+x: F32, +y: F32, +vx: F32, +vy: F32, +dt: F32) -> Cloud:
  Body{F32.add(x, F32.mul(dt, vx)), F32.add(y, F32.mul(dt, vy)), F32.mul(0.999, F32.sub(vx, F32.mul(dt, x))), F32.mul(0.999, F32.sub(vy, F32.mul(dt, y)))}

def advance(cloud: Cloud, +dt: F32) -> Cloud:
  match cloud:
    case Body{x, y, vx, vy}:
      integrate(x, y, vx, vy, dt)
    case Fork{a, b}:
      x y = advance(a, dt) advance(b, dt)
      Fork{x, y}

def positions(cloud: Cloud) -> List<(F32 & F32)>:
  match cloud:
    case Body{x, y, vx, vy}:
      [(x, y)]
    case Fork{a, b}:
      x y = positions(a) positions(b)
      List.append(&1, (F32 & F32), x, y)

def simulate.go(~emit: (U32 & List<(F32 & F32)>) -> IO(Bool), n: Nat, cloud: Cloud, +i: U32, +dt: F32, ok: Bool) -> IO(U32):
  match n ok:
    case 0n _:
      IO.pure(U32, i)
    case 1n+p False{}:
      IO.pure(U32, i)
    case 1n+p True{}:
      do IO<U32>:
        +next : Cloud <- IO.pure(Cloud, advance(cloud, dt))
        go : Bool <- emit((i, positions(next)))
        simulate.go(~emit, p, next, U32.add(i, 1), dt, go)

def simulate(~emit: (U32 & List<(F32 & F32)>) -> IO(Bool), cloud: Cloud, ticks: U32, dt: F32) -> IO(U32):
  simulate.go(~emit, U32.to_nat(ticks), cloud, 0, dt, True{})

# Minimal event workload to separate transport latency from particle work.
def pulse.go(~emit: U32 -> IO(Bool), n: Nat, +i: U32, ok: Bool) -> IO(U32):
  match n ok:
    case 0n _:
      IO.pure(U32, i)
    case 1n+p False{}:
      IO.pure(U32, i)
    case 1n+p True{}:
      do IO<U32>:
        go : Bool <- emit(i)
        pulse.go(~emit, p, U32.add(i, 1), go)

def pulse(~emit: U32 -> IO(Bool), ticks: U32) -> IO(U32):
  pulse.go(~emit, U32.to_nat(ticks), 0, True{})
