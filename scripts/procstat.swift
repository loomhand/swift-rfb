// procstat PID SECONDS: CPU %, context switches/s, wakeups/s and footprint of
// a process over an interval, read from proc_pidinfo and proc_pid_rusage.
import Darwin
import Foundation

struct Sample {
    var cpu: UInt64
    var csw: Int32
    var idle: UInt64
    var interrupt: UInt64
    var footprint: UInt64
    var at: Double
}

func sample(_ pid: pid_t) -> Sample? {
    var task = proc_taskinfo()
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return nil }
    var usage = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let cpu = (task.pti_total_user + task.pti_total_system) * UInt64(timebase.numer) / UInt64(timebase.denom)
    return Sample(cpu: cpu, csw: task.pti_csw, idle: usage.ri_pkg_idle_wkups, interrupt: usage.ri_interrupt_wkups,
                  footprint: usage.ri_phys_footprint, at: Date().timeIntervalSince1970)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]), let seconds = Double(args[2]), let a = sample(pid) else {
    print("usage: procstat PID SECONDS")
    exit(2)
}
Thread.sleep(forTimeInterval: seconds)
guard let b = sample(pid) else { exit(1) }
let dt = b.at - a.at
print(String(format: "cpu=%.2f%% csw/s=%.1f idle_wakeups/s=%.1f interrupt_wakeups/s=%.1f footprint_mb=%.1f interval_s=%.1f",
             Double(b.cpu - a.cpu) / 1e9 / dt * 100, Double(b.csw - a.csw) / dt, Double(b.idle - a.idle) / dt,
             Double(b.interrupt - a.interrupt) / dt, Double(b.footprint) / 1048576, dt))
