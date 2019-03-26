package Monitor::darwin;
use warnings;

if ($^O eq 'darwin') {
    %Monitoring::Tiny::cmds = (
        TOP => '/usr/bin/top -ce -n0 -l1',
        MEM => '/usr/sbin/sysctl -n hw.memsize',
        SWP => '/usr/sbin/sysctl -n vm.swapusage',
        DSK => '/bin/df -m',
        PKG => 'brew outdated -v',
    );
    %Monitoring::Tiny::fields = (
        PhysMem             => [
            MEM => qr/(\d+\w) unused/,
            [qw(free)],
        ],
        SWP                 => [
            SWP => qr/total\s+=\s+(\d+\.\d+\w).+free\s+=\s+(\d+\.\d+\w)/,
            [qw(total free)],
        ],
        'CPU usage'         => [
            CPU => qr/(\d+\.\d+)% user\D+(\d+\.\d+)% sys\D+(\d+\.\d+)% idle/,
            [qw(user sys idle)],
        ],
        Processes           => [
            PRC => qr/(\d+) total\D+(\d+) running\D+(\d+) sleeping/,
            [qw(total running sleeping)],
        ],
        DSK                 => [
            DSK => qr{^/\S+\s+(\w+)\s+[\w.]+\s+(\w+)\s[^/]+(/.*)},
            [qw(total free mount)],
        ],
    );
};

1;
