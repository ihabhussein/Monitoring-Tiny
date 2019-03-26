package Monitor::freebsd;
use warnings;

if ($^O eq 'freebsd') {
    %Monitoring::Tiny::cmds = (
        TOP => '/usr/bin/top -u -d2 -s1',
        MEM => '/sbin/sysctl -n hw.physmem',
        DSK => '/bin/df -m',
        PKG => 'pkg version -vR | grep -v =',
    );
    %Monitoring::Tiny::fields = (
        Mem                 => [
            MEM => qr/(\d+\w) Free/,
            [qw(free)],
        ],
        Swap                => [
            SWP => qr/(\d+\w) Total.+?(\d+\w) Free/,
            [qw(total free)],
        ],
        CPU                 => [
            CPU => qr/(\d+\.\d+)% user.+?(\d+\.\d+)% system.+?(\d+\.\d+)% idle/,
            [qw(user sys idle)],
        ],
        qr/\d+ processes/   => [
            PRC => qr/(\d+) processes\D+(\d+) running\D+(\d+) sleeping/,
            [qw(total running sleeping)],
        ],
        DSK                 => [
            DSK => qr{\S+\s+([\w.]+)\s+\S+\s+([\w.]+)[^/]+(/(?!dev).*)},
            [qw(total free mount)],
        ],
    );
};

1;
