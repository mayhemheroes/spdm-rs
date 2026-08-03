// Copyright (c) 2023 Intel Corporation
//
// SPDX-License-Identifier: Apache-2.0 or MIT

#![no_main]

use libfuzzer_sys::fuzz_target;

include!("../../../fuzz-target/responder/deliver_encapsulated_response_rsp/src/main.rs");

fuzz_target!(|data: &[u8]| {
    // fuzzed code goes here
    executor::block_on(fuzz_handle_deliver_encapsulated_reponse(Arc::new(data.to_vec())));
});
