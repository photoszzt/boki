#include "base/init.h"
#include "base/common.h"
#include "common/flags.h"
#include "gateway/server.h"

#include <signal.h>

ABSL_FLAG(int, engine_conn_port, 10007, "Port for engine connections");
ABSL_FLAG(int, http_port, 8080, "Port for HTTP connections");
ABSL_FLAG(int, grpc_port, 50051, "Port for gRPC connections");
ABSL_FLAG(std::string, func_config_file, "", "Path to function config file");

namespace faas {

static std::atomic<gateway::Server*> server_ptr{nullptr};
static void SignalHandlerToStopServer(int signal) {
    gateway::Server* server = server_ptr.exchange(nullptr);
    if (server != nullptr) {
        server->ScheduleStop();
    }
}

void GatewayMain(int argc, char* argv[]) {
    signal(SIGINT, SignalHandlerToStopServer);
    base::InitMain(argc, argv);
    flags::PopulateHostnameIfEmpty();

    auto server = std::make_unique<gateway::Server>();
    server->set_engine_conn_port(absl::GetFlag(FLAGS_engine_conn_port));
    server->set_http_port(absl::GetFlag(FLAGS_http_port));
    server->set_grpc_port(absl::GetFlag(FLAGS_grpc_port));
    server->set_func_config_file(absl::GetFlag(FLAGS_func_config_file));

    server->Start();
    server_ptr.store(server.get());
    server->WaitForFinish();
}

}  // namespace faas

int main(int argc, char* argv[]) {
    faas::GatewayMain(argc, argv);
    return 0;
}
