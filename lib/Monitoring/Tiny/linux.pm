package Monitor::linux;
use warnings;

if ($^O eq 'linux') {
    %Monitoring::Tiny::cmds = (
        TOP => '/usr/bin/top -b -n1 -d1 | grep -v "^ "',
        DSK => '/bin/df -m',
    );
    %Monitoring::Tiny::fields = (
        '\S+ Mem '          => [
            MEM => qr/(\d+) total\D+(\d+) free/,
            [qw(total free)],
        ],
        '\S+ Swap'          => [
            SWP => qr/(\d+) total\D+(\d+) free/,
            [qw(total free)],
        ],
        '%Cpu(s)'           => [
            CPU => qr/(\d+\.\d+) us.+?(\d+\.\d+) sy.+?(\d+\.\d+) id/,
            [qw(user sys idle)],
        ],
        'Tasks'             => [
            PRC => qr/(\d+) total\D+(\d+) running\D+(\d+) sleeping/,
            [qw(total running sleeping)],
        ],
        DSK                 => [
            DSK => qr{^/\S+\s+(\d+)\s+\S+\s+(\d+)[^/]+(/.*)},
            [qw(total free mount)],
        ],
    );

    if (-x '/usr/bin/apt') {
        $Monitoring::Tiny::cmds{PKG} = 'apt list --upgradable | grep -v Listing';
    }
};

1;
