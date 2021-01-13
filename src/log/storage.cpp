#include "log/storage.h"

#include "utils/bits.h"

namespace faas {
namespace log {

using protocol::SharedLogMessage;
using protocol::SharedLogMessageHelper;
using protocol::SharedLogOpType;

Storage::Storage(uint16_t node_id)
    : StorageBase(node_id),
      log_header_(fmt::format("Storage[{}]: ", node_id)),
      current_view_(nullptr) {}

Storage::~Storage() {}

void Storage::OnViewCreated(const View* view) {
    DCHECK(zk_session()->WithinMyEventLoopThread());
    bool contains_myself = view->contains_storage_node(my_node_id());
    std::vector<SharedLogRequest> ready_requests;
    {
        absl::MutexLock core_lk(&core_mu_);
        if (contains_myself) {
            for (uint16_t sequencer_id : view->GetSequencerNodes()) {
                storage_collection_.InstallLogSpace(std::make_unique<LogStorage>(
                    my_node_id(), view, sequencer_id));
            }
        }
        {
            absl::MutexLock future_request_lk(&future_request_mu_);
            future_requests_.OnNewView(view, contains_myself ? &ready_requests : nullptr);
        }
        current_view_ = view;
    }
    if (!ready_requests.empty()) {
        if (!contains_myself) {
            HLOG(FATAL) << fmt::format("Have requests for view {} not including myself",
                                       view->id());
        }
        SomeIOWorker()->ScheduleFunction(
            nullptr, [this, requests = std::move(ready_requests)] {
                ProcessRequests(requests);
            }
        );
    }
}

void Storage::OnViewFinalized(const FinalizedView* finalized_view) {
    DCHECK(zk_session()->WithinMyEventLoopThread());
    absl::ReaderMutexLock core_lk(&core_mu_);
    DCHECK_EQ(finalized_view->view()->id(), current_view_->id());
    storage_collection_.ForEachActiveLogSpace(
        finalized_view->view(),
        [finalized_view, this] (uint32_t logspace_id, LockablePtr<LogStorage> storage_ptr) {
            auto locked_storage = storage_ptr.Lock();
            bool success = locked_storage->Finalize(
                finalized_view->final_metalog_position(logspace_id),
                finalized_view->tail_metalogs(logspace_id));
            if (!success) {
                HLOG(FATAL) << fmt::format("Failed to finalize log space {}",
                                            bits::HexStr0x(logspace_id));
            }
        }
    );
}

#define ONHOLD_IF_FROM_FUTURE_VIEW(MESSAGE_VAR, PAYLOAD_VAR)        \
    do {                                                            \
        if (current_view_ == nullptr                                \
                || (MESSAGE_VAR).view_id > current_view_->id()) {   \
            absl::MutexLock future_request_lk(&future_request_mu_); \
            future_requests_.OnHoldRequest(                         \
                SharedLogRequest(MESSAGE_VAR, PAYLOAD_VAR));        \
            return;                                                 \
        }                                                           \
    } while (0)

#define IGNORE_IF_FROM_PAST_VIEW(MESSAGE_VAR)                       \
    do {                                                            \
        if (current_view_ != nullptr                                \
                && (MESSAGE_VAR).view_id < current_view_->id()) {   \
            HLOG(WARNING) << "Receive outdate request from view "   \
                          << (MESSAGE_VAR).view_id;                 \
            return;                                                 \
        }                                                           \
    } while (0)

void Storage::HandleReadAtRequest(const SharedLogMessage& request) {
    DCHECK(SharedLogMessageHelper::GetOpType(request) == SharedLogOpType::READ_AT);
    LockablePtr<LogStorage> storage_ptr;
    {
        absl::ReaderMutexLock core_lk(&core_mu_);
        ONHOLD_IF_FROM_FUTURE_VIEW(request, EMPTY_CHAR_SPAN);
        storage_ptr = storage_collection_.GetLogSpace(request.logspace_id);
    }
    if (storage_ptr == nullptr) {
        ProcessReadFromDB(request);
        return;
    }
    LogStorage::ReadResultVec results;
    {
        auto locked_storage = storage_ptr.Lock();
        locked_storage->ReadAt(request);
        locked_storage->PollReadResults(&results);
    }
    ProcessReadResults(results);
}

void Storage::HandleReplicateRequest(const SharedLogMessage& message,
                                     std::span<const char> payload) {
    DCHECK(SharedLogMessageHelper::GetOpType(message) == SharedLogOpType::REPLICATE);
    LockablePtr<LogStorage> storage_ptr;
    {
        absl::ReaderMutexLock core_lk(&core_mu_);
        ONHOLD_IF_FROM_FUTURE_VIEW(message, payload);
        IGNORE_IF_FROM_PAST_VIEW(message);
        storage_ptr = storage_collection_.GetLogSpaceChecked(message.logspace_id);
    }
    LogMetaData metadata;
    log_utils::PopulateMetaDataFromRequest(message, &metadata);
    {
        auto locked_storage = storage_ptr.Lock();
        if (!locked_storage->Store(metadata, payload)) {
            HLOG(ERROR) << "Failed to store log entry";
        }
    }
}

void Storage::OnRecvNewMetaLogs(const SharedLogMessage& message,
                                std::span<const char> payload) {
    DCHECK(SharedLogMessageHelper::GetOpType(message) == SharedLogOpType::METALOGS);
    MetaLogsProto metalogs_proto = log_utils::MetaLogsFromPayload(payload);
    DCHECK_EQ(metalogs_proto.logspace_id(), message.logspace_id);
    LockablePtr<LogStorage> storage_ptr;
    {
        absl::ReaderMutexLock core_lk(&core_mu_);
        ONHOLD_IF_FROM_FUTURE_VIEW(message, payload);
        IGNORE_IF_FROM_PAST_VIEW(message);
        storage_ptr = storage_collection_.GetLogSpaceChecked(message.logspace_id);
    }
    LogStorage::ReadResultVec results;
    {
        auto locked_storage = storage_ptr.Lock();
        for (const MetaLogProto& metalog_proto : metalogs_proto.metalogs()) {
            locked_storage->ProvideMetaLog(metalog_proto);
        }
        locked_storage->PollReadResults(&results);
    }
    ProcessReadResults(results);
}

#undef ONHOLD_IF_FROM_FUTURE_VIEW
#undef IGNORE_IF_FROM_PAST_VIEW

void Storage::ProcessReadResults(const LogStorage::ReadResultVec& results) {
    for (const LogStorage::ReadResult& result : results) {
        const SharedLogMessage& request = result.original_request;
        SharedLogMessage response;
        switch (result.status) {
        case LogStorage::ReadResult::kOK:
            response = SharedLogMessageHelper::NewReadOkResponse();
            log_utils::PopulateMetaDataToResponse(result.log_entry->metadata, &response);
            DCHECK_EQ(response.logspace_id, request.logspace_id);
            DCHECK_EQ(response.seqnum, request.seqnum);
            response.metalog_position = request.metalog_position;
            SendEngineResponse(request, &response,
                               STRING_TO_SPAN(result.log_entry->data));
            break;
        case LogStorage::ReadResult::kLookupDB:
            ProcessReadFromDB(request);
            break;
        case LogStorage::ReadResult::kFailed:
            HLOG(ERROR) << fmt::format("Failed to read log data (logspace={}, seqnum={})",
                                       bits::HexStr0x(request.logspace_id),
                                       bits::HexStr0x(request.seqnum));
            response = SharedLogMessageHelper::NewDataLostResponse();
            SendEngineResponse(request, &response);
            break;
        default:
            UNREACHABLE();
        }
    }
}

void Storage::ProcessReadFromDB(const SharedLogMessage& request) {
    LogEntryProto log_entry;
    bool found = GetLogEntryFromDB(request.logspace_id, request.seqnum, &log_entry);
    if (!found) {
        HLOG(ERROR) << fmt::format("Failed to read log data (logspace={}, seqnum={})",
                                   bits::HexStr0x(request.logspace_id),
                                   bits::HexStr0x(request.seqnum));
        SharedLogMessage response = SharedLogMessageHelper::NewDataLostResponse();
        SendEngineResponse(request, &response);
        return;
    }
    SharedLogMessage response = SharedLogMessageHelper::NewReadOkResponse();
    log_utils::PopulateMetaDataToResponse(log_entry, &response);
    DCHECK_EQ(response.logspace_id, request.logspace_id);
    DCHECK_EQ(response.seqnum, request.seqnum);
    response.metalog_position = request.metalog_position;
    SendEngineResponse(request, &response, STRING_TO_SPAN(log_entry.data()));
}

void Storage::ProcessRequests(const std::vector<SharedLogRequest>& requests) {
    for (const SharedLogRequest& request : requests) {
        MessageHandler(request.message, STRING_TO_SPAN(request.payload));
    }
}

void Storage::BackgroundThreadMain() {
    bool running = true;
    while (running) {
        absl::SleepFor(absl::Milliseconds(100));
        running = state_.load(std::memory_order_acquire) != kStopping;
    }
}

void Storage::SendShardProgressIfNeeded() {
    std::vector<std::pair<uint32_t, std::vector<uint32_t>>> progress_to_send;
    {
        absl::ReaderMutexLock core_lk(&core_mu_);
        if (current_view_ == nullptr) {
            return;
        }
        storage_collection_.ForEachActiveLogSpace(
            current_view_,
            [&progress_to_send] (uint32_t logspace_id, LockablePtr<LogStorage> storage_ptr) {
                auto locked_storage = storage_ptr.Lock();
                std::vector<uint32_t> progress;
                if (locked_storage->GrabShardProgressForSending(&progress)) {
                    progress_to_send.emplace_back(logspace_id, std::move(progress));
                }
            }
        );
    }
    for (const auto& entry : progress_to_send) {
        uint32_t logspace_id = entry.first;
        SharedLogMessage message = SharedLogMessageHelper::NewShardProgressMessage(logspace_id);
        SendSequencerMessage(bits::LowHalf32(logspace_id), &message,
                             VECTOR_TO_CHAR_SPAN(entry.second));
    }
}

}  // namespace log
}  // namespace faas
