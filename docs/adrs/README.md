# Decisions

Every technical decision Pavé has recorded, one record each, numbered in the order they were
taken. Each says what was decided, what else was considered and why it lost, and what follows
from it. Read the one behind a part of the code before proposing to change it.

A record is not rewritten when things move on. A later one revises it and says so in its
status. Decisions taken before the first record are described in the README's
**Development** section and in the code's comments; they get a record when they are revisited.

Decisions that hold for every app of the P suite are recorded in
[p-suite](https://github.com/Srynetix/p-suite/tree/main/docs/adrs); a record here can cite them.

To add one: copy the shape of the latest record to the next number, and add its line below.

## The project

| # | Decided | In force |
|---|---|---|
| [1](0001-in-line-with-the-p-suite.md) | Pavé follows the P suite's conventions: swift-format, the suite's recipes, a checked gate and commits, MIT OR Apache-2.0. | Yes |
