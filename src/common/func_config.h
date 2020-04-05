#pragma once

#include "base/common.h"

namespace faas {

class FuncConfig {
public:
    FuncConfig() {}
    ~FuncConfig() {}

    static constexpr int kMaxFuncId = std::numeric_limits<uint16_t>::max();

    struct Entry {
        std::string func_name;
        int func_id;
        std::unordered_set<std::string> grpc_methods;
    };

    bool Load(std::string_view json_path);

    const Entry* find_by_func_name(std::string_view func_name) const {
        if (entires_by_func_name_.count(std::string(func_name)) > 0) {
            return entires_by_func_name_.at(std::string(func_name));
        } else {
            return nullptr;
        }
    }

    const Entry* find_by_func_id(int func_id) const {
        if (entries_by_func_id_.count(func_id) > 0) {
            return entries_by_func_id_.at(func_id);
        } else {
            return nullptr;
        }
    }

private:
    std::vector<std::unique_ptr<Entry>> entries_;
    std::unordered_map<std::string, Entry*> entires_by_func_name_;
    std::unordered_map<int, Entry*> entries_by_func_id_;

    static bool ValidateFuncId(int func_id);
    static bool ValidateFuncName(std::string_view func_name);

    DISALLOW_COPY_AND_ASSIGN(FuncConfig);
};

}  // namespace faas